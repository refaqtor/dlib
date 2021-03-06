/*
Copyright (c) 2016 Timur Gafarov 

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

/**
 * Copyright: Eugene Wissner 2016-.
 * License: $(LINK2 boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors: Eugene Wissner
 */
module dlib.async.event.kqueue;

version (OSX)
{
    version = MissingKevent;
}
else version (iOS)
{
    version = MissingKevent;
}
else version (TVOS)
{
    version = MissingKevent;
}
else version (WatchOS)
{
    version = MissingKevent;
}
else version (OpenBSD)
{
    version = MissingKevent;
}
else version (DragonFlyBSD)
{
    version = MissingKevent;
}

version (MissingKevent)
{
    extern (C):
    nothrow:
    @nogc:

    import core.stdc.stdint;    // intptr_t, uintptr_t
    import core.sys.posix.time; // timespec

    enum : short
    {
        EVFILT_READ     =  -1,
        EVFILT_WRITE    =  -2,
        EVFILT_AIO      =  -3, /* attached to aio requests */
        EVFILT_VNODE    =  -4, /* attached to vnodes */
        EVFILT_PROC     =  -5, /* attached to struct proc */
        EVFILT_SIGNAL   =  -6, /* attached to struct proc */
        EVFILT_TIMER    =  -7, /* timers */
        EVFILT_MACHPORT =  -8, /* Mach portsets */
        EVFILT_FS       =  -9, /* filesystem events */
        EVFILT_USER     = -10, /* User events */
        EVFILT_VM       = -12, /* virtual memory events */
        EVFILT_SYSCOUNT =  11
    }

    extern(D) void EV_SET(kevent_t* kevp, typeof(kevent_t.tupleof) args)
    {
        *kevp = kevent_t(args);
    }

    struct kevent_t
    {
        uintptr_t    ident; /* identifier for this event */
        short       filter; /* filter for event */
        ushort       flags;
        uint        fflags;
        intptr_t      data;
        void        *udata; /* opaque user data identifier */
    }

    enum
    {
        /* actions */
        EV_ADD      = 0x0001, /* add event to kq (implies enable) */
        EV_DELETE   = 0x0002, /* delete event from kq */
        EV_ENABLE   = 0x0004, /* enable event */
        EV_DISABLE  = 0x0008, /* disable event (not reported) */

        /* flags */
        EV_ONESHOT  = 0x0010, /* only report one occurrence */
        EV_CLEAR    = 0x0020, /* clear event state after reporting */
        EV_RECEIPT  = 0x0040, /* force EV_ERROR on success, data=0 */
        EV_DISPATCH = 0x0080, /* disable event after reporting */

        EV_SYSFLAGS = 0xF000, /* reserved by system */
        EV_FLAG1    = 0x2000, /* filter-specific flag */

        /* returned values */
        EV_EOF      = 0x8000, /* EOF detected */
        EV_ERROR    = 0x4000, /* error, data contains errno */
    }

    int kqueue();
    int kevent(int kq, const kevent_t *changelist, int nchanges,
               kevent_t *eventlist, int nevents,
               const timespec *timeout);
}

version (OSX)
{
    version = MacBSD;
}
else version (iOS)
{
    version = MacBSD;
}
else version (FreeBSD)
{
    version = MacBSD;
    public import core.sys.freebsd.sys.event;
}
else version (OpenBSD)
{
    version = MacBSD;
}
else version (DragonFlyBSD)
{
    version = MacBSD;
}

version (MacBSD):

import dlib.async.event.selector;
import dlib.async.loop;
import dlib.async.transport;
import dlib.async.watcher;
import dlib.memory;
import dlib.memory.mmappool;
import dlib.network.socket;
import core.stdc.errno;
import core.sys.posix.unistd;
import core.sys.posix.sys.time;
import core.time;
import std.algorithm.comparison;

class KqueueLoop : SelectorLoop
{
    protected int fd;
    private kevent_t[] events;
    private kevent_t[] changes;
    private size_t changeCount;

    /**
     * Returns: Maximal event count can be got at a time
     *          (should be supported by the backend).
     */
    override protected @property inout(uint) maxEvents() inout const pure nothrow @safe @nogc
    {
        return cast(uint) events.length;
    }

    this()
    {
        super();

        if ((fd = kqueue()) == -1)
        {
            throw MmapPool.instance.make!BadLoopException("epoll initialization failed");
        }
        events = MmapPool.instance.makeArray!kevent_t(64);
        changes = MmapPool.instance.makeArray!kevent_t(64);
    }

    /**
     * Free loop internals.
     */
    ~this()
    {
        MmapPool.instance.dispose(events);
        MmapPool.instance.dispose(changes);
        close(fd);
    }

    private void set(socket_t socket, short filter, ushort flags)
    {
        if (changes.length <= changeCount)
        {
            MmapPool.instance.resizeArray(changes, changeCount + maxEvents);
        }
        EV_SET(&changes[changeCount],
               cast(ulong) socket,
               filter,
               flags,
               0U,
               0L,
               null);
        ++changeCount;
    }

    /**
     * Should be called if the backend configuration changes.
     *
     * Params:
     *     watcher   = Watcher.
     *     oldEvents = The events were already set.
     *     events    = The events should be set.
     *
     * Returns: $(D_KEYWORD true) if the operation was successful.
     */
    override protected bool reify(ConnectionWatcher watcher,
                                  EventMask oldEvents,
                                  EventMask events)
    {
        if (events != oldEvents)
        {
            if (oldEvents & Event.read || oldEvents & Event.accept)
            {
                set(watcher.socket.handle, EVFILT_READ, EV_DELETE);
            }
            if (oldEvents & Event.write)
            {
                set(watcher.socket.handle, EVFILT_WRITE, EV_DELETE);
            }
        }
        if (events & (Event.read | events & Event.accept))
        {
            set(watcher.socket.handle, EVFILT_READ, EV_ADD | EV_ENABLE);
        }
        if (events & Event.write)
        {
            set(watcher.socket.handle, EVFILT_WRITE, EV_ADD | EV_DISPATCH);
        }
        return true;
    }

    /**
     * Does the actual polling.
     */
    protected override void poll()
    {
        timespec ts;
        blockTime.split!("seconds", "nsecs")(ts.tv_sec, ts.tv_nsec);

        if (changeCount > maxEvents) 
        {
            MmapPool.instance.resizeArray(events, changes.length);
        }

        auto eventCount = kevent(fd, changes.ptr, cast(int) changeCount, events.ptr, maxEvents, &ts);
        changeCount = 0;

        if (eventCount < 0)
        {
            if (errno != EINTR)
            {
                throw defaultAllocator.make!BadLoopException();
            }
            return;
        }

        for (int i; i < eventCount; ++i)
        {
            assert(connections.length > events[i].ident);

            IOWatcher io = cast(IOWatcher) connections[events[i].ident];
            // If it is a ConnectionWatcher. Accept connections.
            if (io is null)
            {
                acceptConnections(connections[events[i].ident]);
            }
            else if (events[i].flags & EV_ERROR)
            {
                kill(io, null);
            }
            else if (events[i].filter == EVFILT_READ)
            {
                auto transport = cast(SelectorStreamTransport) io.transport;
                assert(transport !is null);

                SocketException exception;
                try
                {
                    ptrdiff_t received;
                    do
                    {
                        received = transport.socket.receive(io.output[]);
                        io.output += received;
                    }
                    while (received);
                }
                catch (SocketException e)
                {
                    exception = e;
                }
                if (transport.socket.disconnected)
                {
                    kill(io, exception);
                }
                else if (io.output.length)
                {
                    swapPendings.insertBack(io);
                }
            }
            else if (events[i].filter == EVFILT_WRITE)
            {
                auto transport = cast(SelectorStreamTransport) io.transport;
                assert(transport !is null);

                transport.writeReady = true;
                if (transport.input.length)
                {
                    feed(transport);
                }
            }
        }
    }

    /**
     * Returns: The blocking time.
     */
    override protected @property inout(Duration) blockTime()
    inout @safe pure nothrow
    {
        return min(super.blockTime, 1.dur!"seconds");
    }

    /**
     * If the transport couldn't send the data, the further sending should
     * be handled by the event loop.
     *
     * Params:
     *     transport = Transport.
     *     exception = Exception thrown on sending.
     *
     * Returns: $(D_KEYWORD true) if the operation could be successfully
     *          completed or scheduled, $(D_KEYWORD false) otherwise (the
     *          transport is be destroyed then).
     */
    protected override bool feed(SelectorStreamTransport transport, SocketException exception = null)
    {
        if (!super.feed(transport, exception))
        {
            return false;
        }
        if (!transport.writeReady)
        {
            set(transport.socket.handle, EVFILT_WRITE, EV_DISPATCH);
            return true;
        }
        return false;
    }
}
