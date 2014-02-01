/*
Copyright (c) 2014 Martin Cejp 

Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dlib.filesystem.localfilesystem;

import dlib.core.stream;
import dlib.filesystem.filesystem;

import std.array;
import std.conv;
import std.datetime;
import std.path;
import std.stdio;
import std.string;

LocalFileSystem localFS;

static this() {
    localFS = new LocalFileSystem;
}

version (Posix) {
    import core.sys.posix.dirent;
    import core.sys.posix.fcntl;
    import core.sys.posix.sys.stat;
    import core.sys.posix.sys.types;
    import core.sys.posix.unistd;
}
else version (Windows) {
    import core.sys.windows.windows;
    import std.utf;

    enum DWORD NO_ERROR = 0;
}

// Rename stat to stat_ because of method name collision
version (Linux) {
    alias off_t = off64_t;
    alias stat_t = stat64_t;
    
    alias lseek = lseek64;
    alias open = open64;
    alias stat_ = stat64;
}
else version (Posix) {
    alias stat_ = stat;
}

version (Posix)
private class PosixDirectory : Directory {
    LocalFileSystem fs;
    DIR* dir;
    string prefix;
    
    this(LocalFileSystem fs, DIR* dir, string prefix) {
        this.fs = fs;
        this.dir = dir;
        this.prefix = prefix;
    } 
    
    ~this() {
        close();
    }
    
    void close() {
        if (dir != null) {
            closedir(dir);
            dir = null;
        }
    }
    
    FileIterator contents() {
        if (dir == null)
            return null;        // FIXME: throw an error
        
        class Iterator : FileIterator {
            override bool next(out string path, FileStat* stat) {
                dirent entry_buf;
                dirent* entry;
                
                for (;;) {
                    readdir_r(dir, &entry_buf, &entry);
                    
                    if (entry == null)
                        return false;
                    else {
                        string name = to!string(cast(const char*) entry.d_name);
                        
                        if (name == "." || name == "..")
                            continue;
                        
                        path = prefix ~ name;
                        
                        if (stat != null)
                            return fs.stat(path, *stat);
                        else
                            return true;
                    }
                }
            }
        }
        
        return new Iterator;
    }
}

version (Windows)
class WindowsDirectory : Directory {
    LocalFileSystem fs;
    HANDLE find = INVALID_HANDLE_VALUE;
    string prefix;
    
    WIN32_FIND_DATAW entry;
    bool entryValid = false;

    this(LocalFileSystem fs, string path, string prefix) {
        this.fs = fs;
        this.prefix = prefix;

        find = FindFirstFileW(toUTF16z(path ~ `\*.*`), &entry);

        if (find != INVALID_HANDLE_VALUE)
            entryValid = true;
    }
    
    ~this() {
        close();
    }
    
    void close() {
        if (find != INVALID_HANDLE_VALUE) {
            FindClose(find);
            find = INVALID_HANDLE_VALUE;
        }
    }

    FileIterator contents() {
        class Iterator : FileIterator {
            override bool next(out string path, FileStat* stat_out) {
                for (;;) {
                    WIN32_FIND_DATAW* entry = nextEntry();
                    
                    if (entry == null)
                        return false;
                    else {
                        size_t len = wcslen(entry.cFileName.ptr);
                        string name = to!string(entry.cFileName[0..len]);
                        
                        if (name == "." || name == "..")
                            continue;
                        
                        path = prefix ~ name;
                        
                        if (stat_out != null) {
                            if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                                stat_out.isDirectory = true;
                            else
                                stat_out.isFile = true;

                            stat_out.sizeInBytes = (cast(FileSize) entry.nFileSizeHigh << 32) | entry.nFileSizeLow;
                            stat_out.creationTimestamp = SysTime(FILETIMEToStdTime(&entry.ftCreationTime));
                            stat_out.modificationTimestamp = SysTime(FILETIMEToStdTime(&entry.ftLastWriteTime));

                            return true;
                        }
                        else
                            return true;
                    }
                }
            }
        }
        
        return new Iterator;
    }

    private WIN32_FIND_DATAW* nextEntry() {
        if (entryValid) {
            entryValid = false;
            return &entry;
        }

        if (find == INVALID_HANDLE_VALUE || !FindNextFileW(find, &entry))
            return null;

        return &entry;
    }
}

/// LocalFileSystem
class LocalFileSystem : FileSystem {
    override InputStream openForInput(string filename) {
        return cast(InputStream) openFile(filename, read, 0);
    }
    
    override OutputStream openForOutput(string filename, uint creationFlags) {
        return cast(OutputStream) openFile(filename, write, creationFlags); 
    }
    
    override IOStream openForIO(string filename, uint creationFlags) {
        return openFile(filename, read | write, creationFlags);
    }
    
    override bool createDir(string path, bool recursive) {
        import std.algorithm;
        
        if (recursive) {
            ptrdiff_t index = max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
            
            if (index != -1)
                createDir(path[0..index], true);
        }
        
        version (Posix) {
            return mkdir(toStringz(path), access_0755) == 0;
        }
        else version (Windows) {
            return CreateDirectoryW(toUTF16z(path), null) != 0;
        }
        else
            throw new Exception("Not implemented.");
    }
    
    override Directory openDir(string path) {
        // TODO: Windows implementation
        
        version (Posix) {
            DIR* d = opendir(!path.empty ? toStringz(path) : ".");
            
            if (d == null)
                return null;
            else
                return new PosixDirectory(this, d, !path.empty ? path ~ "/" : "");
        }
        else version (Windows) {
            string npath = !path.empty ? buildNormalizedPath(path) : ".";
            DWORD attributes = GetFileAttributesW(toUTF16z(npath));

            enum DWORD INVALID_FILE_ATTRIBUTES = cast(DWORD)0xFFFFFFFF;

            if (attributes == INVALID_FILE_ATTRIBUTES)
                return null;

            if (attributes & FILE_ATTRIBUTE_DIRECTORY)
                return new WindowsDirectory(this, npath, !path.empty ? path ~ "/" : "");
            else
                return null;
        }
        else
            throw new Exception("Not implemented.");
    }
    
    override bool stat(string path, out FileStat stat_out) {
        version (Posix) {
            stat_t st;

            if (stat_(toStringz(path), &st) != 0)
                return false;

            stat_out.isFile = S_ISREG(st.st_mode);
            stat_out.isDirectory = S_ISDIR(st.st_mode);

            stat_out.sizeInBytes = st.st_size;
            stat_out.creationTimestamp = SysTime(unixTimeToStdTime(st.st_ctime));
            stat_out.modificationTimestamp = SysTime(unixTimeToStdTime(st.st_mtime));

            return true;
        }
        else version (Windows) {
            WIN32_FILE_ATTRIBUTE_DATA data;

            if (!GetFileAttributesExW(toUTF16z(path), GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard, &data))
                return false;

            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                stat_out.isDirectory = true;
            else
                stat_out.isFile = true;

            stat_out.sizeInBytes = (cast(FileSize) data.nFileSizeHigh << 32) | data.nFileSizeLow;
            stat_out.creationTimestamp = SysTime(FILETIMEToStdTime(&data.ftCreationTime));
            stat_out.modificationTimestamp = SysTime(FILETIMEToStdTime(&data.ftLastWriteTime));

            return true;
        }
        else
            throw new Exception("Not implemented.");
    }
    
    override bool move(string path, string newPath) {
        // TODO: Windows implementation
        // TODO: should we allow newPath to actually be a directory?
        
        return rename(toStringz(path), toStringz(newPath)) == 0;
    }
    
    override bool remove(string path, bool recursive) {
        FileStat stat;
        
        if (!this.stat(path, stat))
            return false;
        
        return remove(path, stat, recursive);
    }
    
    override FileIterator findFiles(string baseDir, bool recursive, bool delegate(string path) filter) {
        class Iterator : FileIterator {
            string[] entries;
            
            this(string[] entries) {
                this.entries = entries;
            }
            
            bool next(out string path, FileStat* stat_out) {
                if (entries.empty)
                    return false;
                
                path = entries[0];
                entries.popFront();
                
                if (stat_out != null)
                    return stat(path, *stat_out);
                else
                    return true;
            }
        }
        
        // TODO: lazy evaluation
        string[] entries;
        
        findFiles(baseDir, recursive, filter, delegate int(string path) {
            entries ~= path;
            return 0;
        });
        
        return new Iterator(entries);
    }
    
    override int findFiles(string baseDir, bool recursive, bool delegate(string path) filter, int delegate(string path) dg) {
        Directory dir = openDir(baseDir);

        if (dir is null)
            return 0;
        
        try {
            int result = 0;
        
            foreach (string path, FileStat stat; dir) {
                if (filter && filter(path)) {
                    result = dg(path);
                
                    if (result != 0)
                        return result;
                }
                
                if (recursive && stat.isDirectory) {
                    result = findFiles(path, recursive, filter, dg);
                
                    if (result != 0)
                        return result;
                }
            }
            
            return result;
        }
        finally {
            dir.close();
        }
    }
    
private:
    version (Posix) {
        enum access_0644 = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH;
        enum access_0755 = S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH;
    }

    IOStream openFile(string filename, uint accessFlags, uint creationFlags) {
        // TODO: Windows implementation
        
        version (Posix) {
            int flags;
            
            switch (accessFlags & (read | write)) {
                case read: flags = O_RDONLY; break;
                case write: flags = O_WRONLY; break;
                case read | write: flags = O_RDWR; break;
                default: flags = 0;
            }
            
            if (creationFlags & FileSystem.create)
                flags |= O_CREAT;
            
            if (creationFlags & FileSystem.truncate)
                flags |= O_TRUNC;
            
            int fd = open(toStringz(filename), flags, access_0644);
            
            if (fd < 0)
                return null;
            else
                return new PosixFile(fd, accessFlags);
        }
        else version (Windows) {
            DWORD access = 0;

            if (accessFlags & read)
                access |= GENERIC_READ;

            if (accessFlags & write)
                access |= GENERIC_WRITE;

            DWORD creationMode;

            final switch (creationFlags & (create | truncate)) {
                case 0: creationMode = OPEN_EXISTING; break;
                case create: creationMode = OPEN_ALWAYS; break;
                case truncate: creationMode = TRUNCATE_EXISTING; break;
                case create | truncate: creationMode = CREATE_ALWAYS; break;
            }

            HANDLE file = CreateFileW(toUTF16z(filename), access, FILE_SHARE_READ, null, creationMode,
                FILE_ATTRIBUTE_NORMAL, null);

            if (file == INVALID_HANDLE_VALUE)
                return null;
            else
                return new WindowsFile(file, accessFlags);
        }
        else
            throw new Exception("Not implemented.");
    }
    
    bool remove(string path, const ref FileStat stat, bool recursive) {
        // TODO: Windows implementation
        
        if (stat.isDirectory && recursive) {
            // Remove contents
            auto dir = openDir(path);
            
            try {
                foreach (string entryPath, FileStat stat; dir)
                    remove(entryPath, stat, true);
            }
            finally {
                dir.close();
            }
        }
            
        version (Posix) {
            if (stat.isDirectory) 
                return rmdir(toStringz(path)) == 0;
            else
                return std.stdio.remove(toStringz(path)) == 0;
        }
        else version (Windows) {
            if (stat.isDirectory)
                return RemoveDirectoryW(toUTF16z(path)) != 0;
            else
                return DeleteFileW(toUTF16z(path)) != 0;
        }
        else
            throw new Exception("Not implemented.");
    }
}

version (Posix)
class PosixFile : IOStream {
    int fd;
    uint accessFlags;
    bool eof = false;
    
    this(int fd, uint accessFlags) {
        this.fd = fd;
        this.accessFlags = accessFlags;
    }
    
    ~this() {
        close();
    }

    override void close() {
        if (fd != -1) {
            core.sys.posix.unistd.close(fd);
            fd = -1;
        }
    }
    
    override bool seekable() {
        return true;
    }
    
    override StreamPos getPosition() {
        import core.sys.posix.stdio;
        
        return lseek(fd, 0, SEEK_CUR);
    }
    
    override bool setPosition(StreamPos pos) {
        import core.sys.posix.stdio;
        
        return lseek(fd, pos, SEEK_SET) == pos;
    }
    
    override StreamSize size() {
        import core.sys.posix.stdio;
        
        auto off = lseek(fd, 0, SEEK_CUR);
        auto end = lseek(fd, 0, SEEK_END);
        lseek(fd, off, SEEK_SET);
        return end;
    }
    
    override bool readable() {
        return fd != -1 && (accessFlags & FileSystem.read) && !eof;
    }
    
    override size_t readBytes(void* buffer, size_t count) {
        immutable size_t got = core.sys.posix.unistd.read(fd, buffer, count);
        
        if (count > got)
            eof = true;
        
        return got;
    }
    
    override bool writeable() {
        return fd != -1 && (accessFlags & FileSystem.write);
    }
    
    override size_t writeBytes(const void* buffer, size_t count) {
        return core.sys.posix.unistd.write(fd, buffer, count);
    }
    
    override void flush() {
    }
}

version (Windows)
class WindowsFile : IOStream {
    HANDLE handle;
    uint accessFlags;
    bool eof = false;
    
    this(HANDLE handle, uint accessFlags) {
        this.handle = handle;
        this.accessFlags = accessFlags;
    }
    
    ~this() {
        close();
    }

    override void close() {
        if (handle != INVALID_HANDLE_VALUE) {
            CloseHandle(handle);
            handle = INVALID_HANDLE_VALUE;
        }
    }
    
    override bool seekable() {
        return true;
    }
    
    override StreamPos getPosition() {
        LONG pos_high = 0;
        LONG pos_low = SetFilePointer(handle, 0, &pos_high, FILE_CURRENT);

        if (pos_low == INVALID_SET_FILE_POINTER && GetLastError() != NO_ERROR) {
            // FIXME: error
        }

        return cast(StreamPos) pos_high << 32 | pos_low;
    }
    
    override bool setPosition(StreamPos pos) {
        LONG pos_high = pos >> 32;

        if (SetFilePointer(handle, cast(LONG) pos, &pos_high, FILE_BEGIN) == INVALID_SET_FILE_POINTER
            && GetLastError() != NO_ERROR)
            return false;
        else
            return true;
    }
    
    override StreamSize size() {
        DWORD size_high;
        DWORD size_low = GetFileSize(handle, &size_high);

        if (size_low == INVALID_FILE_SIZE && GetLastError() != NO_ERROR) {
            // FIXME: error
        }

        return cast(StreamPos) size_high << 32 | size_low;
    }
    
    override bool readable() {
        return handle != INVALID_HANDLE_VALUE && (accessFlags & FileSystem.read) && !eof;
    }
    
    override size_t readBytes(void* buffer, size_t count) {
        // TODO: make sure that count fits in a DWORD
        DWORD dwCount = cast(DWORD) count;

        DWORD dwGot = void;
        // FIXME: check for errors
        ReadFile(handle, buffer, dwCount, &dwGot, null);

        if (dwCount > dwGot)
            eof = true;
        
        return dwGot;
    }
    
    override bool writeable() {
        return handle != INVALID_HANDLE_VALUE && (accessFlags & FileSystem.write);
    }
    
    override size_t writeBytes(const void* buffer, size_t count) {
        // TODO: make sure that count fits in a DWORD
        DWORD dwCount = cast(DWORD) count;

        DWORD dwGot;
        // FIXME: check for errors
        WriteFile(handle, buffer, dwCount, &dwGot, null);

        return dwGot;
    }
    
    override void flush() {
    }    
}

unittest {
    // TODO: test >4GiB files
    
    import std.conv;
    import std.regex;
    import std.stdio;
    
    FileSystem fs = new LocalFileSystem;

    fs.remove("tests", true);
    
    assert(fs.openDir("tests") is null);
    
    assert(fs.createDir("tests/test_data/main", true));
    
    void printStat(string filename) {
        FileStat stat;
        assert(localFS.stat(filename, stat));
        
        writef("'%s'\t", filename);
        
        if (stat.isFile)
            writefln("%u", stat.sizeInBytes);
        else if (stat.isDirectory)
            writefln("DIR");
        
        writefln("  created: %s", to!string(stat.creationTimestamp));
        writefln("  modified: %s", to!string(stat.modificationTimestamp));
    }
    
    writeln("File stats:");
    printStat("package.json");
    printStat("dlib/core");     // make sure slashes work on Windows
    writeln();
    
    enum dir = "dlib/filesystem";
    writefln("Listing contents of %s:", dir);
    
    auto d = fs.openDir(dir);
    
    try {
        foreach (string path, FileStat stat; d)
            writefln("%s: %u bytes", path, stat.sizeInBytes);
    }
    finally {
        d.close();
    }
    
    writeln();
    
    writeln("Listing dlib/core/*.d:");

    foreach (string path, FileStat stat; localFS.findFiles("", true, delegate bool(string path) {
            return !matchFirst(path, `^dlib/core/.*\.d$`).empty;
        })) {
        writefln("%s: %u bytes", path, stat.sizeInBytes);
    }

    writeln();

    //
    OutputStream outp = fs.openForOutput("tests/test_data/main/hello_world.txt", FileSystem.create | FileSystem.truncate);
    assert(outp);
    
    try {
        assert(outp.writeArray("Hello, World!\n"));
    }
    finally {
        outp.close();
    }
    
    //
    InputStream inp = fs.openForInput("tests/test_data/main/hello_world.txt");
    assert(inp);
    
    try {
        while (inp.readable) {
            char buffer[1];
            
            auto have = inp.readBytes(buffer.ptr, buffer.length);
            std.stdio.write(buffer[0..have]);
        }
    }
    finally {
        inp.close();
    }

    writeln();
}