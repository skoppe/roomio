module roomio.connection;

import roomio.id;
import roomio.port;
import roomio.transport;

import vibe.core.log;
import vibe.core.core;
import vibe.core.concurrency : Isolated;


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
  private {
    Isolated!(Opener) opener;
  }
  this(Id id, Port port, Id other, string host, ushort hostport, uint packetSize) {
    super(id, port, other, Direction.Out, host, hostport);
    opener = port.createOpener(packetSize);
    assert(port.type == PortType.Input);
    assert(packetSize > 0, "PacketSize cannot be 0");
    logInfo("Opening outgoing Connection %s to %s : %s", port.name, host, hostport);
    runWorkerTaskH((Isolated!(Opener) opener, string host, ushort hostport){
      opener.extract.start(new Transport(host, hostport, hostport, false));
    }, opener, host, hostport);
  }
  override void kill() {
    //opener.kill();
    // TODO: call runWorkerTaskH.kill
  }
}

class IncomingConnection : Connection {
  private {
    Isolated!(Opener) opener;
  }
  this(Id id, Port port, Id other, string host, ushort hostport, uint packetSize) {
    super(id, port, other, Direction.In, host, hostport);
    logInfo("Opening incoming connection %s from %s : %s", port.name, host, hostport);
    assert(port.type == PortType.Output);
    assert(packetSize > 0, "PacketSize cannot be 0");
    opener = port.createOpener(packetSize);
    runWorkerTaskH((Isolated!(Opener) opener, string host, ushort hostport){
      opener.extract.start(new Transport(host, hostport, hostport, false));
    }, opener, host, hostport);
  }
  override void kill() {
    //opener.kill();
    // TODO: call runWorkerTaskH.kill
  }
}
