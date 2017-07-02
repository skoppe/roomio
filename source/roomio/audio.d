module roomio.audio;

import roomio.port;
import roomio.id;
import roomio.transport;
import roomio.messages;

import vibe.core.core;

import deimos.portaudio;
import std.string;
import core.stdc.config;
import std.stdio;

private shared PaError initStatus;

shared static this() {
	initStatus = Pa_Initialize();
}

shared static ~this() {
	Pa_Terminate();
}

class InputPort : Port
{
	private {
		PaStream* stream;
		PaDeviceIndex idx;
		PaTime latency;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate) {
		this.idx = idx;
		super(Id.random(), PortType.Input, name, channels, samplerate);
	}
	override void start(Transport transport)
	{
		extern (C) static int callback(const(void) *input, void *output, c_ulong frameCount, const(PaStreamCallbackTimeInfo)* timeInfo, PaStreamCallbackFlags statusFlags, void* userData) {
			Transport transport = cast(Transport)userData;
			short[] data = (cast(short*)input)[0..frameCount];
			transport.send(AudioMessage(data, 0));

			return 0;
		}
		auto inputDeviceInfo = Pa_GetDeviceInfo(idx);
		auto inputParams = PaStreamParameters(idx, cast(int)this.channels, paInt16, inputDeviceInfo.defaultLowInputLatency, null);
		auto result = Pa_OpenStream(&stream, &inputParams, null, this.samplerate, paFramesPerBufferUnspecified, 0, &callback, cast(void*)transport );
		if (result != paNoError) {
			writeln(Pa_GetErrorText(result).fromStringz);
		} else
		{
			Pa_StartStream(stream);
			latency = Pa_GetStreamInfo(stream).inputLatency;
		}
	}
	override void kill() {
		Pa_CloseStream(this.stream);
	}
}

class OutputPort : Port
{
	private {
		PaStream* stream;
		PaDeviceIndex idx;
		PaTime latency;
		Task tid;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate) {
		this.idx = idx;
		super(Id.random(), PortType.Output, name, channels, samplerate);
	}
	override void start(Transport transport)
	{
		auto outputDeviceInfo = Pa_GetDeviceInfo(idx);
		auto outputParams = PaStreamParameters(idx, cast(int)channels, paInt16, outputDeviceInfo.defaultLowOutputLatency, null);
		auto result = Pa_OpenStream(&stream, null, &outputParams, samplerate, paFramesPerBufferUnspecified, 0, null, null );
		if (result != paNoError) {
			writeln(Pa_GetErrorText(result).fromStringz);
		} else
		{
			Pa_StartStream(stream);
			latency = Pa_GetStreamInfo(stream).outputLatency;
		}
		tid = runTask({
			while(1) {
				auto raw = transport.acceptRaw();
				switch (raw.header.type) {
					case MessageType.Audio:
						auto audio = readMessage!(AudioMessage)(raw.data);
						Pa_WriteStream(stream, cast(void*)audio.buffer, audio.buffer.length / channels);
						break;
					default: break;
				}
			}
		});
	}
	override void kill() {
		tid.interrupt();
		Pa_CloseStream(this.stream);
	}
}

auto getPorts() {
	import std.string;
	import std.conv : text;

	auto idx = Pa_GetDefaultHostApi();
	auto apiInfo = Pa_GetHostApiInfo(idx);
	string apiName = apiInfo.name.fromStringz.text;
	Port[] ports;
	if (apiInfo.defaultInputDevice != paNoDevice)
	{
		auto inputDeviceInfo = Pa_GetDeviceInfo(apiInfo.defaultInputDevice);
		ports ~= new InputPort(apiInfo.defaultInputDevice, apiName ~ ": " ~ inputDeviceInfo.name.fromStringz.text, 1, 44100.0);
	}
	if (apiInfo.defaultOutputDevice != paNoDevice)
	{
		auto outputDeviceInfo = Pa_GetDeviceInfo(apiInfo.defaultOutputDevice);
		ports ~= new OutputPort(apiInfo.defaultOutputDevice, apiName ~ ": " ~ outputDeviceInfo.name.fromStringz.text, 1, 44100.0);
	}
	return ports;
}
