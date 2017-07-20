import roomio.device;
import roomio.transport;
import roomio.id;
import roomio.audio;
import deimos.portaudio;

import std.getopt;
import vibe.core.core;
import vibe.core.args;
import vibe.core.log;
import roomio.cli;
  import std.stdio;
  import std.socket : Socket;


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

  Transport transport;
  Device device;
  auto ports = getPorts();

  bool running = true;
  auto task = runTask({
      transport = new Transport(ip, port, 54544, true);
      logInfo("Connected");
      device = new Device(Id.random, Socket.hostName(), transport, ports);

      auto deviceList = new DeviceList(transport);
      auto deviceLatencies = new DeviceLatency(transport, device);
      deviceList.sync();
      startCli(transport, deviceList, deviceLatencies);

      device.connect();

      while(running) {
        transport.acceptMessage();
      }
  });

  runEventLoop();

  running = false;
  task.join();
  device.close();
  logInfo("Closing connection");
  transport.close();

  return 0;
}
