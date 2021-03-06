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
module dlib.async.watcher;

import dlib.async.loop;
import dlib.async.protocol;
import dlib.async.transport;
import dlib.container.buffer;
import dlib.memory;
import dlib.memory.mmappool;
import dlib.network.socket;
import std.functional;
import std.exception;

version (Windows)
{
    import core.sys.windows.basetyps;
    import core.sys.windows.mswsock;
    import core.sys.windows.winbase;
    import core.sys.windows.windef;
    import core.sys.windows.winsock2;
}

/**
 * A watcher is an opaque structure that you allocate and register to record
 * your interest in some event. 
 */
abstract class Watcher
{
    /// Whether the watcher is active.
    bool active;

    /**
     * Invoke some action on event.
     */
    void invoke();
}

class ConnectionWatcher : Watcher
{
    /// Watched socket.
    private Socket socket_;

    /// Protocol factory.
    protected Protocol delegate() protocolFactory;

    package PendingQueue!IOWatcher incoming;

    /**
     * Params:
     *     socket = Socket.
     */
    this(Socket socket)
    {
        socket_ = socket;
        incoming = MmapPool.instance.make!(PendingQueue!IOWatcher);
    }

    /// Ditto.
    protected this()
    {
    }

    ~this()
    {
        MmapPool.instance.dispose(incoming);
    }

    /*
     * Params:
     *     P = Protocol should be used.
     */
    void setProtocol(P : Protocol)()
    {
        this.protocolFactory = () => cast(Protocol) MmapPool.instance.make!P;
    }

    /**
     * Returns: Socket.
     */
    @property inout(Socket) socket() inout pure nothrow @nogc
    {
        return socket_;
    }

    /**
     * Returns: New protocol instance.
     */
    @property Protocol protocol()
    in
    {
        assert(protocolFactory !is null, "Protocol isn't set.");
    }
    body
    {
        return protocolFactory();
    }

    /**
     * Invokes new connection callback.
     */
    override void invoke()
    {
        foreach (io; incoming)
        {
            io.protocol.connected(cast(DuplexTransport) io.transport);
        }
    }
}

/**
 * Contains a pending watcher with the invoked events or a transport can be
 * read from.
 */
class IOWatcher : ConnectionWatcher
{
    /// If an exception was thrown the transport should be already invalid.
    private union
    {
        StreamTransport transport_;
        SocketException exception_;
    }

    private Protocol protocol_;

    /**
     * Returns: Underlying output buffer.
     */
    package ReadBuffer output;

    /**
     * Params:
     *     transport = Transport.
     *     protocol  = New instance of the application protocol.
     */
    this(StreamTransport transport, Protocol protocol)
    in
    {
        assert(transport !is null);
        assert(protocol !is null);
    }
    body
    {
        super();
        transport_ = transport;
        protocol_ = protocol;
        output = MmapPool.instance.make!ReadBuffer();
        active = true;
    }

    /**
     * Destroys the watcher.
     */
    protected ~this()
    {
        MmapPool.instance.dispose(output);
        MmapPool.instance.dispose(protocol_);
    }

    /**
     * Assigns a transport.
     *
     * Params:
     *     transport = Transport.
     *     protocol  = Application protocol.
     *
     * Returns: $(D_KEYWORD this).
     */
    IOWatcher opCall(StreamTransport transport, Protocol protocol) pure nothrow @safe @nogc
    in
    {
        assert(transport !is null);
        assert(protocol !is null);
    }
    body
    {
        transport_ = transport;
        protocol_ = protocol;
        active = true;
        return this;
    }

    /**
     * Returns: Transport used by this watcher.
     */
    @property inout(StreamTransport) transport() inout pure nothrow @nogc
    {
        return transport_;
    }

    /**
     * Sets an exception occurred during a read/write operation.
     *
     * Params:
     *     exception = Thrown exception.
     */
    @property void exception(SocketException exception) pure nothrow @nogc
    {
        exception_ = exception;
    }

    /**
     * Returns: Application protocol.
     */
    override @property Protocol protocol() pure nothrow @safe @nogc
    {
        return protocol_;
    }

    /**
     * Returns: Socket.
     */
    override @property inout(Socket) socket() inout pure nothrow @nogc
    {
        return transport.socket;
    }

    /**
     * Invokes the watcher callback.
     */
    override void invoke()
    {
        if (output.length)
        {
            protocol.received(output[0..$]);
            output.clear();
        }
        else
        {
            protocol.disconnected(exception_);
            active = false;
        }
    }
}
