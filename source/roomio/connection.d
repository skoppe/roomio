module roomio.connection;

import roomio.id;
import roomio.port;
import roomio.transport;

import vibe.core.log;

enum Direction {
  In,
  Out
}

struct ConnectionInfo {
  Id id;
  Id source;
  Id target;
  Direction direction;
  string host;
  ushort port;
}

abstract class Connection {
  Id id;
  Id other;
  Port port;
  Direction direction;
  string host;
  ushort hostport;
  this(Id id, Port port, Id other, Direction direction, string host, ushort hostport) {
    this.id = id;
    this.port = port;
    this.other = other;
    this.direction = direction;
    this.host = host;
    this.hostport = hostport;
  }
  ConnectionInfo getInfo() {
    if (direction == Direction.In) {
      return ConnectionInfo(id, other, port.id, direction, host, hostport);
    }
    return ConnectionInfo(id, port.id, other, direction, host, hostport);
  }
  void kill() { 
    port.kill();
  }
}

class OutgoingConnection : Connection {
  private Transport transport;
  this(Id id, Port port, Id other, string host, ushort hostport) {
    super(id, port, other, Direction.Out, host, hostport);
    logInfo("Opening outgoing connection %s to %s : %s", port.name, host, hostport);
    assert(port.type == PortType.Input);
    transport = new Transport(host, hostport, hostport, false);
    port.start(transport);
  }
}

class IncomingConnection : Connection {
  private Transport transport;
  this(Id id, Port port, Id other, string host, ushort hostport) {
    super(id, port, other, Direction.In, host, hostport);
    logInfo("Opening incoming connection %s from %s : %s", port.name, host, hostport);
    assert(port.type == PortType.Output);
    transport = new Transport(host, hostport, hostport, false);
    port.start(transport);
  }
}
