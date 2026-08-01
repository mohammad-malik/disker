import Foundation

/// One directory entry as returned by `getattrlistbulk(2)`.
struct BulkEntry {
    var name: String = ""
    var objectType: UInt32 = 0
    var deviceID: Int32 = 0
    var fileID: UInt64 = 0
    var allocatedSize: UInt64 = 0
    var linkCount: UInt32 = 1
    var accessTime: Date?

    var isDirectory: Bool { objectType == VDIR.rawValue }
    var isRegularFile: Bool { objectType == VREG.rawValue }
    var isSymlink: Bool { objectType == VLNK.rawValue }
}

/// Wraps `getattrlistbulk(2)`, which returns many directory entries with their metadata in a
/// single syscall. The Foundation enumerator issues a `stat` per entry; on a volume with
/// millions of files that difference dominates total scan time.
///
/// The buffer layout is positional: fields appear in a fixed canonical order defined by the
/// kernel, not in the order requested. Parsing therefore has to follow that exact order, and
/// consult `ATTR_CMN_RETURNED_ATTRS` because a filesystem may decline to supply a field.
enum BulkDirectoryReader {

    /// 64 KB typically yields a few hundred entries per syscall — past this the returns flatten.
    static let bufferSize = 64 * 1024

    enum ReadError: Error {
        case cannotOpen(errno: Int32)
    }

    /// Reads every entry in `path`. Symlinks are reported but never followed.
    static func read(path: String, into sink: (BulkEntry) -> Void) throws {
        // Retried on EINTR rather than reported as a failure. A directory whose open was
        // merely interrupted by a signal is perfectly readable, but the caller cannot tell
        // that apart from a denial and marks it unreadable — which both loses its contents
        // from the total and inflates the "N items could not be read" warning that is
        // supposed to mean "grant Full Disk Access". This showed up only under concurrency:
        // scanning with one worker reported 217 unreadable directories and with sixteen,
        // 227, the difference being exactly nine interrupted opens.
        var fd: Int32 = -1
        while true {
            fd = open(path, O_RDONLY | O_DIRECTORY, 0)
            if fd >= 0 { break }
            if errno == EINTR { continue }
            throw ReadError.cannotOpen(errno: errno)
        }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_ACCTIME)
            | attrgroup_t(ATTR_CMN_FILEID)
        attrList.fileattr =
            attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { buffer.deallocate() }

        while true {
            let count = withUnsafeMutablePointer(to: &attrList) { listPtr in
                getattrlistbulk(fd, listPtr, buffer, bufferSize, 0)
            }
            // 0 means exhausted. A negative return is an error, and treating it as the end
            // of the directory would silently drop every remaining entry — so an interrupted
            // call is retried rather than quietly truncating the listing mid-directory.
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }

            var cursor = buffer
            for _ in 0..<count {
                let entryLength = cursor.loadUnaligned(as: UInt32.self)
                if let entry = parse(cursor) { sink(entry) }
                cursor = cursor.advanced(by: Int(entryLength))
            }
        }
    }

    /// Decodes a single entry.
    ///
    /// Every multi-byte read is unaligned: `getattrlistbulk` packs fields without inserting
    /// padding, so an `off_t` routinely lands on a 4-byte boundary. Aligned loads would be
    /// undefined behaviour here.
    private static func parse(_ base: UnsafeRawPointer) -> BulkEntry? {
        var offset = MemoryLayout<UInt32>.size  // skip the leading entry length

        // ATTR_CMN_RETURNED_ATTRS is always first when requested, and states which of the
        // remaining fields are actually present.
        let returned = base.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size

        var entry = BulkEntry()
        let common = returned.commonattr
        let file = returned.fileattr

        // --- Common attributes, in kernel canonical order ---

        if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let ref = base.loadUnaligned(fromByteOffset: offset, as: attrreference_t.self)
            let namePtr = base.advanced(by: offset + Int(ref.attr_dataoffset))
            entry.name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
            offset += MemoryLayout<attrreference_t>.size
        }

        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            entry.deviceID = base.loadUnaligned(fromByteOffset: offset, as: dev_t.self)
            offset += MemoryLayout<dev_t>.size
        }

        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            entry.objectType = base.loadUnaligned(fromByteOffset: offset, as: fsobj_type_t.self)
            offset += MemoryLayout<fsobj_type_t>.size
        }

        if common & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
            let ts = base.loadUnaligned(fromByteOffset: offset, as: timespec.self)
            // Zero is the filesystem saying "no value", not 1970.
            if ts.tv_sec > 0 {
                entry.accessTime = Date(timeIntervalSince1970: TimeInterval(ts.tv_sec))
            }
            offset += MemoryLayout<timespec>.size
        }

        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            entry.fileID = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += MemoryLayout<UInt64>.size
        }

        // --- File attributes follow all common attributes; LINKCOUNT precedes ALLOCSIZE ---

        if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += MemoryLayout<UInt32>.size
        }

        if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            let allocated = base.loadUnaligned(fromByteOffset: offset, as: off_t.self)
            entry.allocatedSize = allocated > 0 ? UInt64(allocated) : 0
            offset += MemoryLayout<off_t>.size
        }

        // "." and ".." are never returned by getattrlistbulk, but an empty name means the
        // filesystem gave us something unusable — skip rather than create a nameless node.
        return entry.name.isEmpty ? nil : entry
    }
}
