module roomio.cli;

import roomio.transport;
import roomio.device;
import roomio.id;
import roomio.port;
import roomio.messages;

import vibe.stream.stdio;
import vibe.stream.operations;
import vibe.core.core;
import vibe.core.log;

import std.meta : AliasSeq;
import std.range : isInputRange, ElementType, empty, front;
import std.algorithm : map, joiner, find, filter;
import std.format : format;
import std.conv : to;
import std.array : array;

import option;

alias mapOpt = option.map;

alias CliHandler = void delegate(ref CliState, const(char[]) entry);

struct CliState {
	Transport transport;
	DeviceList devices;
	DeviceLatency latencies;
	CliHandler handler;
	bool running = true;
}

struct CliCommand {
	string name;
	string description;
}

auto singleOpt(Range)(Range range)
	if (isInputRange!Range)
{
	if (range.empty)
		return None!(ElementType!Range);
	return Some(range.front);
}

@CliCommand("list", "Lists known devices")
void listDevices(ref CliState state) {
	auto idPortMapper = state.devices.getDevices().map!(d => d.ports.map!(p => tuple!("device","port")(d,p))).joiner();
	auto getPortDevice(Id id) {
		return idPortMapper.find!(m => m.port.id == id).singleOpt();
	}
	auto devices = state.devices.getDevices();
	foreach(device; devices) {
		logInfo("Device: %s", device.name);
		logInfo("\tPorts:");
		foreach(port; device.ports) {
			logInfo("\t\t%s: %s - %s", port.id, port.type, port.name);
		}
		logInfo("\tConnections:");
		foreach(connection; device.connections) {
			auto source = getPortDevice(connection.source).mapOpt!(t => format("%s:%s", t.device.name, t.port.name)).getOrElse(connection.source.toString);
			auto target = getPortDevice(connection.target).mapOpt!(t => format("%s:%s", t.device.name, t.port.name)).getOrElse(connection.target.toString);
			logInfo("\t\t%s -> %s at %s : %s", source, target, connection.host, connection.port);
		}
	}
}

@CliCommand("latencies", "lists devices latencies")
void listLatencies(ref CliState state) {
	auto devices = state.devices.getDevices;
	auto latencies = state.latencies.getLatencies;
	foreach(device; devices) {
		if (auto latency = device.id in latencies) {
			logInfo("Device: %s", device.name);
			logInfo("	Latency: %s mean, %s stddev, %s local max", latency.mean, latency.getStd, latency.getMax);
		}
	}
}

@CliCommand("deviations", "lists devices sync deviations")
void listDeviations(ref CliState state) {
	auto devices = state.devices.getDevices;
	auto latencies = state.latencies.getDeviations;
	foreach(device; devices) {
		if (auto latency = device.id in latencies) {
			logInfo("Device: %s", device.name);
			logInfo("	Deviation: %s mean, %s stddev, %s local max", latency.mean, latency.getStd, latency.getMax);
		}
	}
}

@CliCommand("connect", "Connect one port to another")
void connectPort(ref CliState state) {

	auto devices = state.devices.getDevices();
	auto devicePorts = devices.map!(d => d.ports.map!(p => tuple!("device","port")(d,p))).joiner();
	auto inputs = devicePorts.filter!(t => t.port.type == PortType.Input).array();
	auto outputs = devicePorts.filter!(t => t.port.type == PortType.Output).array();
	if (inputs.length == 0)
		return logInfo("There are no input ports to connect");
	if (outputs.length == 0)
		return logInfo("There are no output ports to connect");
	auto createConfirmation(T)(T input, T output) {
		logInfo("Do you want to connect %s - %s to %s - %s?", input.device.name, input.port.name, output.device.name, output.port.name);
		return delegate (ref CliState state, const(char[]) entry){
			if (entry[0] == 'y' || entry[0] == 'Y' ||
				entry[0] == 'j' || entry[0] == 'J')
			{
				// connect
				logInfo("Connecting.");
				state.transport.send(LinkCommandMessage([0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9], input.port.id, output.port.id, Id.random(), "239.255.255.99", 53533, 256));
			} else
				logInfo("Abort");
			state.handler = null;
			return;
		};
	}
	int parseInt(const(char[]) entry, int min, ulong max) {
		int no = entry.to!int;
		if (no < min || no > max)
			throw new Exception("Invalid number. Abort.");
		return no;
	}
	void chooseOutput(T)(T input) {
		logInfo("Choose output port to connect: ");
		foreach(idx, p; outputs)
			logInfo("%s) %s - %s", idx+1, p.device.name, p.port.name);

		state.handler = delegate (ref CliState state, const(char[]) entry){
			int no = parseInt(entry, 1, outputs.length);
			state.handler = createConfirmation(input, outputs[no-1]);
		};
	}
	void chooseInput() {
		logInfo("Choose input port to connect: ");
		foreach(idx, p; inputs)
			logInfo("%s) %s - %s", idx+1, p.device.name, p.port.name);

		state.handler = delegate (ref CliState state, const(char[]) entry){
			int no = parseInt(entry, 1, inputs.length);
			chooseOutput(inputs[no-1]);
		};
	}
	if (inputs.length == 1 && outputs.length == 1)
	{
		if (inputs.front.device.id == outputs.front.device.id)
			throw new Exception("Only one device with ports available. Abort.");

		auto del = createConfirmation(inputs.front, outputs.front);
		state.handler = del;
		return;
	}
	if (inputs.length > 1)
	{
		chooseInput();
		return;
	}
	chooseOutput(inputs.front);
}

@CliCommand("exit")
void exit(ref CliState state) {
	state.handler = delegate (ref CliState state, const(char[]) entry) {};
	state.running = false;
}

@CliCommand("help")
void help(ref CliState state) {
	import std.traits : getUDAs;
	enum commands = cliCommands!();
	logInfo("These are the root level commands:\n");
	foreach(m; commands) {
		alias symbol = AliasSeq!(__traits(getMember, roomio.cli, m));
		enum com = getUDAs!(symbol, CliCommand)[0];
		logInfo("\t%s\t\t%s", com.name, com.description);
	}
	logInfo("\n");
}

template cliCommands() {
	import std.traits : hasUDA;
	import std.meta : Filter;
	import std.typecons : Tuple;

	template onlyCliCommand(alias T) {
		alias symbol = AliasSeq!(__traits(getMember, roomio.cli, T));
		static if (__traits(compiles, hasUDA!(symbol, CliCommand)))
			enum onlyCliCommand = hasUDA!(symbol, CliCommand);
		else
			enum onlyCliCommand = false;
	}
	enum cliCommands = Filter!(onlyCliCommand, __traits(allMembers, roomio.cli));
}

void executeCommand(ref CliState state, const(char[]) entry) {
	import std.traits : hasUDA, getUDAs;
	if (state.handler)
	{
		try { 
			state.handler(state, entry);
		} catch (Exception e) {
			logInfo("%s",e.msg);
			state.handler = null;
		}
		return;
	}
	enum commands = cliCommands!();
	foreach(m; commands) {
		alias symbol = AliasSeq!(__traits(getMember, roomio.cli, m));
		if (getUDAs!(symbol, CliCommand)[0].name == entry) {
			symbol[0](state);
			return;
		}
	}
}

void startCli(Transport transport, DeviceList devices, DeviceLatency latencies) {
	auto state = CliState(transport, devices, latencies);
  runTask({
    auto stdin = new StdinStream();
    logInfo("Interactive session started. Type 'help' when you get stuck.");
    while(state.running) {
      auto line = stdin.readLine(size_t.max, "\x0a");
      executeCommand(state, cast(const(char[]))line);
    }
    exitEventLoop();
  });
}