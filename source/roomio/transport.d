module roomio.transport;

import roomio.id;
import roomio.port;
import roomio.connection;
import roomio.messages;
import vibe.core.net;
import core.sys.posix.netinet.in_;
import roomio.testhelpers;
import std.meta : staticMap, AliasSeq;
import std.traits : EnumMembers, Parameters, hasMember;
import std.uni : toLower;
import std.algorithm : findSplit;
import std.array : Appender;
import core.time : msecs;
import std.typecons : tuple;

struct UdpVibeD {
  private {
    UDPConnection conn;
    NetworkAddress addr;
  }
  this(string ip, ushort port, ushort targetPort, bool loopback = true) {
    conn = listenUDP(port);
    NetworkAddress multiaddr = resolveHost(ip, AF_INET);
    conn.addMembership(multiaddr);
    conn.canBroadcast = true;
    conn.multicastLoopback = loopback;
    addr = resolveHost(ip,AF_INET,false);
    addr.port = targetPort;
  }
  void send(const ubyte[] data) {
    conn.send(data, &addr);
  }
  auto receive(ubyte[] buffer) {
    return conn.recv(1000.msecs, buffer);
  }
  void close() {
    conn.close();
  }
}

class Transport {
  private {
    UdpVibeD udp;
    Dispatcher dispatcher;
    ubyte[] buffer;
    Appender!(ubyte[]) outBuffer;
    ubyte[] getBuffer(size_t size) {
      if (buffer.length >= size)
        return buffer[0..size];
      buffer = new ubyte[size*2];
      return buffer[0..size];
    }
  }
  this(string ip, ushort port, ushort targetPort, bool loopback = true) {
    udp = UdpVibeD(ip, port, targetPort, loopback);
    getBuffer(2500);
  }
  void close() {
    udp.close();
  }
  void connect(Device)(Device device) {
    dispatcher.connect(device);
  }
  void send(T)(T msg) {
    import vibe.core.log;
    writeMessage(msg, outBuffer);
    //logInfo("Sending: %s (%s bytes)", msg, outBuffer.data.length);
    udp.send(outBuffer.data);
    outBuffer.clear();
  }
  auto acceptRaw() {
    auto buf = udp.receive(getBuffer(2500));
    auto header = readHeader(buf);
    // TODO: Handle message fragmentation
    return tuple!("header","data")(header, buf);
  }
  void acceptMessage() {
    import vibe.core.log;
    enum headerSize = messageSize(Header.init);
    try {
      auto buf = udp.receive(getBuffer(2500));
      auto header = readHeader(buf);
      // TODO: Handle message fragmentation
      processMessage(header, buf, dispatcher);
    } catch (Exception e) {
      //logInfo("Failed to receive: %s", e);
    }
  }
}

enum MessageEnumTypes = __traits(allMembers, MessageType);
alias MessageTypes = staticMap!(getMessageType, MessageEnumTypes);
void processMessage(Dispatcher)(ref Header header, const ubyte[] raw, auto ref Dispatcher dispatcher) {
  final switch (header.type) {
    foreach(item; MessageEnumTypes) {
      mixin("enum C = MessageType."~item~";");
    case C:
      alias MsgType = getMessageType!item;
      dispatcher.processMessage(readMessage!MsgType(raw));
      return;
    }
  }
}

@("processMessage")
unittest {
  auto raw = serialize(LeaveMessage(Id.test));
  struct Test {
    bool called = false;
    MessageType msgType;
    void processMessage(T)(T msg) {
      called = true;
    }
  }
  auto t = Test();
  auto header = readHeader(raw);
  processMessage!(Test)(header, raw, t);
  t.called.shouldEqual(true);
}

template getMessageType(alias T) {
  mixin("alias getMessageType = "~mixin(T.stringof)~"Message;");
}

struct Dispatcher {
  alias MessageDelegate(T) = void delegate(ref T);
  template DelegatesField(MsgType) {
    enum DelegatesField = MsgType.stringof.findSplit("Message")[0].toLower;
  }
  MessageDelegate!(PingMessage)[] ping;
  MessageDelegate!(PongMessage)[] pong;
  MessageDelegate!(JoinMessage)[] join;
  MessageDelegate!(LeaveMessage)[] leave;
  MessageDelegate!(QueryMessage)[] query;
  MessageDelegate!(InfoMessage)[] info;
  MessageDelegate!(LinkCommandMessage)[] linkcommand;
  MessageDelegate!(LinkReplyMessage)[] linkreply;
  MessageDelegate!(UnlinkMessage)[] unlink;
  MessageDelegate!(LatencyQueryMessage)[] latencyquery;
  MessageDelegate!(LatencyInfoMessage)[] latencyinfo;
  void connect(Device)(Device device) {
    template firstArg(alias fun) {
      alias firstArg = Parameters!fun[0];
    }
    static if (!hasMember!(Device,"onMessage"))
      static assert("Type must have onMessage function");
    foreach (t; __traits(getOverloads, Device, "onMessage")) {
      alias arg = firstArg!t;
      foreach(MsgType; MessageTypes) {
        static if (is(arg : MsgType)) {
          __traits(getMember, this, DelegatesField!MsgType) ~= &device.onMessage;
        }
      }
    }
  }
  void processMessage(Message)(Message msg) {
    foreach(MsgType; MessageTypes) {
      static if (is(Message : MsgType)) {
        static if (hasMember!(typeof(this),DelegatesField!MsgType)) {
          mixin("alias delegates = "~DelegatesField!MsgType~";");
          foreach(del; delegates)
            del(msg);
        }
      }
    }
  }
}

@("Dispatcher")
unittest {
  class Test {
    PingMessage msg;
    void onMessage(ref PingMessage msg) {
      this.msg = msg;
    }
  }
  auto test = new Test();
  auto t = Dispatcher();
  t.connect(test);
  auto msg = PingMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9],Id.random);
  t.processMessage(msg);
  test.msg.shouldEqual(msg);
}

class MessageLogger {
  void log(T)(auto ref T msg) {
    import vibe.core.log;
    logInfo("Received: %s", msg);
  }
  void onMessage(ref PingMessage msg) {
    log(msg);
  }
  void onMessage(ref JoinMessage msg) {
    log(msg);
  }
  void onMessage(ref PongMessage msg) {
    log(msg);
  }
  void onMessage(ref LeaveMessage msg) {
    log(msg);
  }
  void onMessage(ref QueryMessage msg) {
    log(msg);
  }
  void onMessage(ref InfoMessage msg) {
    log(msg);
  }
  void onMessage(ref LinkCommandMessage msg) {
    log(msg);
  }
  void onMessage(ref LinkReplyMessage msg) {
    log(msg);
  }
  void onMessage(ref UnlinkMessage msg) {
    log(msg);
  }
}
