module roomio.port;

import roomio.id;
import roomio.transport;

import vibe.core.concurrency : Isolated;

enum PortType {
  Input = 1,
  Output = 2
}

struct PortInfo {
  Id id;
  PortType type;
  string name;
  uint channels;
  double samplerate;
}

abstract class Opener {
  void start(Transport transport);
  void kill();
}

abstract class Port {
  Id id;
  PortType type;
  string name;
  uint channels;
  double samplerate;
  this(Id id, PortType t, string n, uint c, double s)
  {
    this.id = id;
    type = t;
    name = n;
    channels = c;
    samplerate = s;
  }
  PortInfo getInfo() {
    return PortInfo(id, type, name, channels, samplerate);
  }
  Isolated!(Opener) createOpener(uint packetSize);
}
