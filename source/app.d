import roomio.device;
import roomio.transport;
import roomio.id;

import std.getopt;
import vibe.core.core;
import vibe.core.args;

int main(string[] args){

  auto ip = "239.255.255.100";
  ushort port = 16999;
  readOption("p|port", &port, "Port of client (default: 16999)");

  try {
    if (!finalizeCommandLineOptions())
      return 0;
  } catch (Exception e) {
    printCommandLineHelp ();
    return 1;
  }

  auto transport = new Transport(ip, port, 1900);
  auto logger = new MessageLogger();
  auto device = new Device!Transport(Id.random, "device", transport);

  transport.connect(logger);

  bool running = true;
  runTask({
      while(running) {
        transport.acceptMessage();
      }
    });
  runTask({
      device.connect();
    });

  runEventLoop();

  return 0;
}
