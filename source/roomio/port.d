module roomio.port;

import roomio.id;

enum PortType {
  Input = 1,
  Output = 2
}

struct PortInfo {
  Id id;
  PortType type;
  string name;
  uint channels;
  uint samplerate;
}

class Port {
  Id id;
  PortInfo getInfo() {
    return PortInfo(id);
  }
}
