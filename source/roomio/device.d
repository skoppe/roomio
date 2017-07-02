module roomio.device;

import roomio.id;
import roomio.port;
import roomio.connection;
import roomio.messages;
import roomio.transport;
import roomio.testhelpers;
import std.meta : staticMap, AliasSeq;
import std.traits : EnumMembers, Parameters, hasMember;
import std.uni : toLower;
import std.algorithm : findSplit, map, find;
import std.array : array;
import std.range : empty, front;

struct DeviceInfo
{
  Id id;
  string name;
  PortInfo[] ports;
  ConnectionInfo[] connections;
}

class Device {
  private {
    Id id;
    string name;
    Port[] ports;
    Connection[] connections;
    Transport transport;
  }
  this(Id id, string name, Transport transport, Port[] ports = null, Connection[] connections = null) {
    this.id = id;
    this.name = name;
    this.transport = transport;
    this.ports = ports;
  }
  void connect() {
    transport.connect(this);
    transport.send(JoinMessage(getDeviceInfo()));
  }
  DeviceInfo getDeviceInfo() {
    return DeviceInfo(
                      id,
                      name,
                      ports.map!"a.getInfo".array,
                      connections.map!"a.getInfo".array
                      );
  }
  private void killConnection(Range)(Range range) {
    import std.algorithm : remove;
    if (range.empty)
      return;
    auto connection = range.front();
    connection.kill();
    connections = connections.remove!(c => c is connection);
  }
  private Port getPort(Id id) {
    return null;
  }
  void onMessage(ref PingMessage msg) {
    transport.send(PongMessage(msg.nonce, id));
  }
  void onMessage(ref JoinMessage msg) {}
  void onMessage(ref PongMessage msg) {}
  void onMessage(ref LeaveMessage msg) {}
  void onMessage(ref QueryMessage msg) {
    transport.send(InfoMessage(msg.nonce,getDeviceInfo()));
  }
  void onMessage(ref InfoMessage msg) {}
  void onMessage(ref LinkCommandMessage msg) {
    auto source = getPort(msg.source);
    auto target = getPort(msg.target);
    if (source is null && target is null)
      return;
    if (source !is null && target !is null) {
      transport.send(LinkReplyMessage(msg.nonce, id, LinkStatus.Error, "Source and target cannot be on same device"));
      return;
    }
    killConnection(connections.find!(c => c.port is source || c.port is target));
    if (source !is null) {
      connections ~= new OutgoingConnection(msg.connection, source, msg.target, msg.host, msg.port);
    } else if (target !is null) {
      connections ~= new IncomingConnection(msg.connection, target, msg.source, msg.host, msg.port);
    }
    transport.send(LinkReplyMessage(msg.nonce, id, LinkStatus.Active, ""));
  }
  void onMessage(ref LinkReplyMessage msg) {}
  void onMessage(ref UnlinkMessage msg) {
    killConnection(connections.find!(c => c.id == msg.connection));
  }
  void close() {
    foreach(c; connections)
      c.kill();
    connections = [];
  }
}
