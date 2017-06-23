module roomio.connection;

import roomio.id;
import roomio.port;

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
  void kill();
}

class OutgoingConnection : Connection {
  this(Id id, Port port, Id other, string host, ushort hostport) {
    super(id, port, other, Direction.Out, host, hostport);
  }
  override void kill() {}
}

class IncomingConnection : Connection {
  this(Id id, Port port, Id other, string host, ushort hostport) {
    super(id, port, other, Direction.In, host, hostport);
  }
  override void kill() {}
}
