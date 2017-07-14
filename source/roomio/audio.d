module roomio.audio;

import roomio.port;
import roomio.id;
import roomio.transport;
import roomio.messages;
import roomio.queue;

import vibe.core.core;
import vibe.core.log;

import deimos.portaudio;
import std.string;
import core.stdc.config;
import std.stdio;
import core.time : hnsecs;
import std.datetime : Clock;
import std.conv : to;

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
					transport.send(AudioMessage(buffer[], Clock.currStdTime, samplesCounter));
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
		uint hnsecDelay;
		double hnsecPerSample;
		CircularQueue!(AudioMessage, 48) queue;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate, uint msDelay = 10) {
		this.idx = idx;
		this.hnsecDelay = msDelay * 10_000;
		this.hnsecPerSample = 10_000_000 / samplerate;
		super(Id.random(), PortType.Output, name, channels, samplerate);
	}
	override void start(Transport transport)
	{
		// TODO: need to notify sample size from source to target

		extern(C) static int callback(const(void)* inputBuffer, void* outputBuffer,
		                             size_t framesPerBuffer,
		                             const(PaStreamCallbackTimeInfo)* timeInfo,
		                             PaStreamCallbackFlags statusFlags,
		                             void *userData) {
			OutputPort port = cast(OutputPort)(userData);
			short[] output = (cast(short*)outputBuffer)[0..framesPerBuffer];
			if (port.queue.empty) {
				// we fill everything with silence
				output[0..framesPerBuffer] = 0;
				return paContinue;
			}
			size_t slaveTime = Clock.currStdTime;

			// there is only one path in the while loop that doesn't break
			// that is the path where all samples in the current message can be discarded
			while(true) {
				// playTime is the time the first sample in the message should be played on
				size_t playTime = port.queue.currentRead.masterTime + port.hnsecDelay;

				// when the local time is behind the time the current audio message should be played
				if (slaveTime < playTime) {
					//writefln("Localtime behind %s hnsecs of stream", playTime - slaveTime);
					// we calc how many samples of silence we need before the current audio message should be used
					size_t silenceSamples = ((cast(double)(playTime - slaveTime)) / port.hnsecPerSample).to!size_t;
					// when the amount of samples of silence is bigger than output buffer size
					if (silenceSamples >= framesPerBuffer) {
						// we fill everything with silence
						output[0..framesPerBuffer] = 0;
					} else {
						// otherwise we fill ouput with partial silence and partial audio
						output[0..silenceSamples] = 0;
						output[silenceSamples..$] = port.queue.currentRead.buffer[0..silenceSamples];
					}
					// and break the while loop
					break;
				} else {
					//writefln("Localtime ahead %s hnsecs of stream", slaveTime - playTime);
					// otherwise, we calculate how many samples in the current message can be discarded
					size_t skipSamples = ((cast(double)(slaveTime - playTime)) / port.hnsecPerSample).to!size_t;
					// when that is larger than the samples in the messages
					if (skipSamples >= port.queue.currentRead.buffer.length)
					{
						// we drop the message
						port.queue.advanceRead();
						// we check if the queue is empty
						if (port.queue.empty) {
							// and if so we fill with silence and break while the loop
							output[0..framesPerBuffer] = 0;
							break;
						}
						// if the queue isn't empty we continue the while loop
					} else {
						// when the amount of samples to be skipped is smaller than the amount of samples in the current message
						// we calculate how many samples are left in the audio message
						size_t samplesCopied = port.queue.currentRead.buffer.length - skipSamples;
						// and copy those
						output[0..samplesCopied] = port.queue.currentRead.buffer[skipSamples..$];
						// advance the queue
						port.queue.advanceRead();
						// and if the queue is not empty
						if (!port.queue.empty) {
							// we fill with the audio from the next message
							output[samplesCopied..$] = port.queue.currentRead.buffer[0..skipSamples];
						} else {
							// otherwise we fill with silence
							output[samplesCopied..$] = 0;
						}
						// and break the while loop
						break;
					}
				}
			}

			return paContinue;
		}

		auto outputDeviceInfo = Pa_GetDeviceInfo(idx);
		auto outputParams = PaStreamParameters(idx, cast(int)channels, paInt16, outputDeviceInfo.defaultLowOutputLatency, null);
		auto result = Pa_OpenStream(&stream, null, &outputParams, samplerate, 64, 0, &callback, cast(void*)this );
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
						if (queue.full) {
							continue;
						}
						readMessageInPlace(raw.data, queue.currentWrite());
						//size_t slaveTime = Clock.currStdTime;
						//if (slaveTime > queue.currentWrite.masterTime)
							//writeln("Delay in stream ", slaveTime - queue.currentWrite.masterTime, ", hnsecs (queue ", queue.length, ")");
						queue.advanceWrite();
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
