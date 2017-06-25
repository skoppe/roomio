module roomio.messages;

import roomio.device;
import roomio.id;
import cerealed;
import roomio.testhelpers;
import std.range;

enum MessageType {
  Join,
  Leave,
  Query,
  Info,
  LinkCommand,
  LinkReply,
  Unlink,
  Ping,
  Pong
}

struct Header {
  ubyte version_;
  size_t size;
  MessageType type;
}

struct PingMessage {
  ubyte[20] nonce;
  Id id;
}

struct PongMessage {
  ubyte[20] replyTo;
  Id id;
}

struct JoinMessage {
  DeviceInfo device;
}

struct LeaveMessage {
  Id deviceId;
}

struct QueryMessage {
  ubyte[20] nonce;
}

struct InfoMessage {
  ubyte[20] replyTo;
  DeviceInfo device;
}

struct LinkCommandMessage {
  ubyte[20] nonce;
  Id source;
  Id target;
  Id connection;
  string host;
  ushort port;
}

enum LinkStatus {
  Active,
  Error,
  Dead
}
struct LinkReplyMessage {
  ubyte[20] replyTo;
  Id self;
  LinkStatus status;
  string msg;
}

struct UnlinkMessage {
  Id connection;
}

auto readHeader(ubyte[] raw) {
  return raw.decerealize!Header;
}

struct Packet(T) {
  Header header;
  T message;
}

size_t calcSize(T)(T item) {
  return item.cerealize.length;
}

size_t messageSize(T)(T msg) {
  size_t s;
  foreach(idx, I; msg.tupleof) {
    static if (is(typeof(I) == enum)) {
      s += I.sizeof;
    } else static if (__traits(isStaticArray, I)) {
      s += I.sizeof;
    } else static if (__traits(hasMember, I, "raw")) {
      s += I.raw.sizeof;
    } else static if (is(typeof(I) : P[], P)) {
      static if (__traits(isPOD, P) && !__traits(isScalar, P)) {
        s += calcSize(typeof(I).init);
        foreach(i; I)
          s += messageSize(i);
      } else
        s += calcSize(typeof(I).init) + P.sizeof * I.length;
    } else static if (__traits(isScalar, I)) {
      s += I.sizeof;
    } else {
      s += messageSize(I);
    }
  }
  return s;
}

unittest {
  import roomio.port;
  import roomio.connection;
  void assertMessageSize(T)(T msg) {
    msg.messageSize.shouldEqual(msg.calcSize);
  }
  PortInfo port = PortInfo(Id.random, PortType.Input, "name", 10, 20);
  ConnectionInfo connection = ConnectionInfo(Id.random, Id.random, Id.random, Direction.In);
  DeviceInfo device = DeviceInfo(Id.random, "device", [port, port], [connection, connection] );
  assertMessageSize(LinkReplyMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9], Id.random, LinkStatus.Active, "message"));
  assertMessageSize(UnlinkMessage(Id.random));
  assertMessageSize(LinkCommandMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9], Id.random, Id.random, Id.random));
  assertMessageSize(InfoMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9], device));
  assertMessageSize(QueryMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9]));
  assertMessageSize(LeaveMessage(Id.random));
  assertMessageSize(JoinMessage(device));
}

auto getMessageEnumType(T)(T msg) {
  import std.algorithm : findSplit;
  return mixin("MessageType."~typeof(msg).stringof.findSplit("Message")[0]);
}

void writeMessage(T, Sink)(T msg, ref Sink sink)
  if (isOutputRange!(Sink,ubyte))
{
  enum headerSize = messageSize(Header.init);
  auto size = messageSize(msg);
  sink.reserve(size + headerSize);
  auto type = getMessageEnumType(msg);
  Header hdr = Header(1, size, type);
  auto cerealizer = CerealiserImpl!(Sink)(sink);
  cerealizer.write(hdr);
  cerealizer.write(msg);
}

ubyte[] serialize(T)(T msg) {
  auto app = appender!(ubyte[]);
  writeMessage(msg, app);
  return app.data;
}

unittest {
  import roomio.port;
  import roomio.connection;

  PortInfo port = PortInfo(Id.test, PortType.Input, "name", 10, 20);
  ConnectionInfo connection = ConnectionInfo(Id.test, Id.test, Id.test, Direction.In);
  DeviceInfo device = DeviceInfo(Id.test, "device", [port, port], [connection, connection] );
  serialize(LinkReplyMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9], Id.test, LinkStatus.Active, "message")).shouldEqual([1, 0, 0, 0, 0, 0, 0, 0, 49, 0, 0, 0, 5, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 0, 0, 7, 109, 101, 115, 115, 97, 103, 101]);
  serialize(UnlinkMessage(Id.test)).shouldEqual([1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 6, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171]);
  serialize(LinkCommandMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9], Id.test, Id.test, Id.test)).shouldEqual([1, 0, 0, 0, 0, 0, 0, 0, 72, 0, 0, 0, 4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 0]);
  serialize(InfoMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9], device)).shouldEqual([1, 0, 0, 0, 0, 0, 0, 0, 228, 0, 0, 0, 3, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137,
 171, 0, 6, 100, 101, 118, 105, 99, 101, 0, 2, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 1, 0, 4, 110, 97, 109, 101, 0, 0, 0, 10, 0, 0, 0, 20, 1, 35, 69, 103, 1, 35, 1, 35, 1
, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 1, 0, 4, 110, 97, 109, 101, 0, 0, 0, 10, 0, 0, 0, 20, 0, 2, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1,
35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 0, 0, 0, 0, 0, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1
, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 0, 0, 0, 0, 0]);
  serialize(QueryMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9])).shouldEqual([1, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 2, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  serialize(LeaveMessage(Id.test)).shouldEqual([1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 1, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171]);
  serialize(JoinMessage(device)).shouldEqual([1, 0, 0, 0, 0, 0, 0, 0, 208, 0, 0, 0, 0, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 6, 100, 101, 118, 105, 99, 101, 0, 2, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 1, 0, 4, 110, 97, 109, 101, 0, 0, 0, 10, 0, 0, 0, 20, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 1, 0, 4, 110, 97, 109, 101, 0, 0, 0, 10, 0, 0, 0, 20, 0, 2, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35,1, 35, 69, 103, 137, 171, 0, 0, 0, 0, 0, 0, 0, 0, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171, 0, 0, 0, 0, 0, 0, 0, 0]);
}

Header readHeader(const ubyte[] raw) {
  return raw.decerealize!Header;
}

T readMessage(T)(const ubyte[] raw) {
  enum headerSize = messageSize(Header.init);
  return raw[headerSize..$].decerealize!T;
}
unittest {
  ubyte[] raw = [1, 0, 0, 0, 0, 0, 0, 0, 26, 0, 0, 0, 6, 1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171];
  auto hdr = raw.readHeader();
  hdr.shouldEqual(Header(1,26,MessageType.Unlink));
  auto msg = raw.readMessage!(UnlinkMessage);
  msg.shouldEqual(UnlinkMessage(Id.test));
}
