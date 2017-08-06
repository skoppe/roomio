module roomio.device;

import roomio.id;
import roomio.port;
import roomio.connection;
import roomio.messages;
import roomio.transport;
import roomio.testhelpers;
import roomio.stats;
import std.meta : staticMap, AliasSeq;
import std.traits : EnumMembers, Parameters, hasMember;
import std.uni : toLower;
import std.algorithm : findSplit, map, find;
import std.array : array;
import std.range : empty, front;
import std.random : uniform;

import vibe.core.log;
import vibe.core.core;
import std.datetime : Clock;
import core.time : msecs;

struct DeviceInfo
{
  Id id;
  string name;
  PortInfo[] ports;
  ConnectionInfo[] connections;
}

auto getOrNull(T)(T range) {
  if (range.empty)
    return null;
  return range.front;
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
  private bool killConnection(Range)(Range range) {
    import std.algorithm : remove;
    if (range.empty)
      return false;
    auto connection = range.front();
    connection.kill();
    connections = connections.remove!(c => c is connection);
    return true;
  }
  private Port getPort(Id id) {
    return ports.find!(p => p.id == id).getOrNull;
  }
  void onMessage(ref PingMessage msg) {
    transport.send(PongMessage(msg.nonce, id));
  }
  void onMessage(ref QueryMessage msg) {
    transport.send(InfoMessage(msg.nonce,getDeviceInfo()));
  }
  void onMessage(ref LinkCommandMessage msg) {
    auto source = getPort(msg.source);
    auto target = getPort(msg.target);
    if (source is null && target is null)
      return;
    if (source !is null && target !is null) {
      transport.send(LinkReplyMessage(msg.nonce, id, ConnectionInfo.init, LinkStatus.Error, "Source and target cannot be on same device"));
      return;
    }
    killConnection(connections.find!(c => c.port is source || c.port is target));
    Connection connection;
    if (source !is null) {
      connection = new OutgoingConnection(msg.connection, source, msg.target, msg.host.dup, msg.port, msg.packetSize);
    } else if (target !is null) {
      connection = new IncomingConnection(msg.connection, target, msg.source, msg.host.dup, msg.port, msg.packetSize);
    }
    connections ~= connection;
    transport.send(LinkReplyMessage(msg.nonce, id, connection.getInfo, LinkStatus.Active, ""));
  }
  void onMessage(ref UnlinkMessage msg) {
    auto connectionRange = connections.find!(c => c.id == msg.connection);
    if (connectionRange.empty)
      return;
    killConnection(connectionRange);

    auto connection = connectionRange.front();
    transport.send(LinkReplyMessage(msg.nonce, id, connection.getInfo, LinkStatus.Dead, ""));
  }
  void onMessage(ref LatencyQueryMessage msg) {
    runTask({
      LatencyQueryMessage clone = msg;
      long randomSleep = uniform(0, 500);
      sleep(randomSleep.msecs);
      transport.send(LatencyInfoMessage(clone.origin, id, clone.start, randomSleep, Clock.currStdTime));
    });
  }
  void close() {
    transport.send(LeaveMessage(id));
    foreach(c; connections)
      c.kill();
    connections = [];
  }
}

class DeviceList {
  private Transport transport;
  private DeviceInfo[Id] devices;
  this(Transport transport) {
    this.transport = transport;
    transport.connect(this);
  }
  const(DeviceInfo[]) getDevices() {
    return devices.values;
  }
  void sync() {
    transport.send(QueryMessage());
  }
  void onMessage(ref JoinMessage msg) {
    devices[msg.device.id] = msg.device.dup();
  }
  void onMessage(ref InfoMessage msg) {
    devices[msg.device.id] = msg.device.dup();
  }
  void onMessage(ref LeaveMessage msg) {
    devices.remove(msg.deviceId);
  }
  void onMessage(ref LinkReplyMessage msg) {
    import std.algorithm : countUntil, remove;
    if (auto stored = msg.self in devices)
    {
      if (msg.status == LinkStatus.Active)
      {
        auto idx = (*stored).connections.countUntil!(c => msg.connection.id == c.id);
        if (idx == -1)
        {
          (*stored).connections ~= msg.connection;
        } else
          (*stored).connections[idx] = msg.connection;
      } else
        (*stored).connections = (*stored).connections.remove!(c => msg.connection.id == c.id);
    }
  }
}

class DeviceLatency {
  private Transport transport;
  private RunningStd[Id] latencies;
  private RunningStd[Id] deviations;
  private Device device;
  this(Transport transport, Device device) {
    this.device = device;
    this.transport = transport;
    transport.connect(this);
    runTask({
      sleep((500 + uniform(0,2000)).msecs);
      while(true) {
        transport.send(LatencyQueryMessage(device.id, Clock.currStdTime));
        sleep(2000.msecs);
        sleep(uniform(0,2000).msecs);
      }
    });
  }
  const(RunningStd[Id]) getLatencies() {
    return latencies;
  }
  const(RunningStd[Id]) getDeviations() {
    return deviations;
  }
  void onMessage(ref LatencyInfoMessage msg) {
    if (msg.origin != device.id)
      return;
    double current = Clock.currStdTime;
    double hnsecSleep = (msg.sleep * 10000);
    double rtt = current - hnsecSleep - msg.start;
    double deviation = msg.deviceTime - hnsecSleep - (msg.start + rtt / 2);
    if (auto stddev = msg.device in latencies) {
      (*stddev).add(rtt);
      deviations[msg.device].add(deviation);
    } else
    {
      auto stddev = RunningStd(20);
      stddev.add(rtt);
      latencies[msg.device] = stddev;
      auto devs = RunningStd(20);
      devs.add(deviation);
      deviations[msg.device] = devs;
    }
  }
}