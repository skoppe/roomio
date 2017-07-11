module roomio.audio;

import roomio.port;
import roomio.id;
import roomio.transport;
import roomio.messages;

import vibe.core.core;
import vibe.core.log;

import deimos.portaudio;
import std.string;
import core.stdc.config;
import std.stdio;
import core.time : hnsecs;
import std.datetime : Clock;

import roomio.testhelpers;

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
		bool running = true;
		Task tid;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate) {
		this.idx = idx;
		super(Id.random(), PortType.Input, name, channels, samplerate);
	}
	override void start(Transport transport)
	{
		auto inputDeviceInfo = Pa_GetDeviceInfo(idx);
		auto inputParams = PaStreamParameters(idx, cast(int)this.channels, paInt16, inputDeviceInfo.defaultLowInputLatency, null);
		auto result = Pa_OpenStream(&stream, &inputParams, null, this.samplerate, paFramesPerBufferUnspecified, 0, null, null );
		if (result != paNoError) {
			writeln(Pa_GetErrorText(result).fromStringz);
		} else
		{
			Pa_StartStream(stream);
			latency = Pa_GetStreamInfo(stream).inputLatency;
			tid = runTask({
				short[64] buffer;
				long samplesCounter;
				while(running) {
					Pa_ReadStream(stream, buffer[].ptr, 64);
					transport.send(AudioMessage(buffer[], 0, samplesCounter));
					samplesCounter += 64;
					yield();
				}
				Pa_CloseStream(this.stream);
			});
		}
	}
	override void kill() {
		running = false;
		tid.join();
	}
}

uint calcSamplesDelay(uint channels, double samplerate, uint msDelay = 2, uint sampleGranularity = 64)
{
	double samples = (samplerate / 1000) * channels * msDelay;
	return cast(uint)((samples / sampleGranularity) + 0.5) * sampleGranularity;
}

@("calcSamplesDelay")
unittest {
	calcSamplesDelay(2, 44100, 5, 64).shouldEqual(448);
	calcSamplesDelay(1, 44100, 5, 64).shouldEqual(192);
}

class OutputPort : Port
{
	private {
		PaStream* stream;
		PaDeviceIndex idx;
		PaTime latency;
		Task tid;
		uint sampleDelay;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate, uint msDelay = 2) {
		//this.sampleDelay = (samplerate / 1000) * channels * msDelay;
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
			AudioMessage audio;
			long lastWrite;
			long lastSampleSize;
			long totalOutOfSync;
			long samplesPlayed;
			long samplesSkipped;
			double hnsecPerSample = 10_000_000 / samplerate;
			while(1) {
				auto raw = transport.acceptRaw();
				switch (raw.header.type) {
					case MessageType.Audio:
						readMessageInPlace(raw.data, audio);
						if (samplesPlayed < audio.samplesCounter)
						{
							samplesSkipped += audio.samplesCounter - samplesPlayed;
							totalOutOfSync -= cast(long)(samplesSkipped * hnsecPerSample);
							logInfo("Skipped %s samples", audio.samplesCounter - samplesPlayed);
							samplesPlayed = audio.samplesCounter;
						} else
							samplesPlayed += audio.buffer.length;
						long now = Clock.currStdTime();
						if (lastWrite != 0) {
							auto hnsecStreamElapsed = (now - lastWrite);
							auto hnsecAudioElapsed = cast(long)(lastSampleSize * hnsecPerSample);
							if (hnsecStreamElapsed > hnsecAudioElapsed)
							{
								auto hnsecOutOfSync = hnsecStreamElapsed - hnsecAudioElapsed;
								totalOutOfSync += hnsecOutOfSync;
								logInfo("Out of buffer for %s hnsec (total %sms)", hnsecOutOfSync, totalOutOfSync / 10000);
							}
						} else
						{
							//long initialDelay = cast(long)(((audio.buffer.length >> 1) / this.channels) * hnsecPerSample);
							//// sleep for half buffer length (to account for variation in UDP stream)
							//logInfo("Delay stream for %s hnsecs (%s single channel samples)", initialDelay, (audio.buffer.length >> 1) / this.channels);
							//sleep(initialDelay.hnsecs);
							//now = Clock.currStdTime();
						}
						lastSampleSize = cast(long)(audio.buffer.length / this.channels);
						Pa_WriteStream(stream, cast(void*)audio.buffer, audio.buffer.length);
						lastWrite = now;
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

	auto count = Pa_GetHostApiCount();
	Port[] ports;

	foreach(apiIdx; 0..count) {
		auto apiInfo = Pa_GetHostApiInfo(apiIdx);
		string apiName = apiInfo.name.fromStringz.text;

		foreach(i; 0..apiInfo.deviceCount) {
			auto deviceIdx = Pa_HostApiDeviceIndexToDeviceIndex(apiIdx, i);
			auto info = Pa_GetDeviceInfo(deviceIdx);

			auto name = apiName ~ ": " ~ info.name.fromStringz.text;
			if (info.maxInputChannels > 0) {
				logInfo("Found input device %s",name);
				ports ~= new InputPort(deviceIdx, apiName ~ ": " ~ info.name.fromStringz.text, 1, 44100.0);
			} else {
				logInfo("Found output device %s",name);
				ports ~= new OutputPort(deviceIdx, apiName ~ ": " ~ info.name.fromStringz.text, 1, 44100.0);
			}
		}
	}
	return ports;
}
