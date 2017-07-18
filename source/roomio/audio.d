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
import std.format;
import std.algorithm : max, min;
import std.math;

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
				long sampleCounter;
				long startTime = Clock.currStdTime;
				while(running) {
					Pa_ReadStream(stream, buffer[].ptr, 64);
					transport.send(AudioMessage(buffer[], startTime, sampleCounter));
					sampleCounter += 64;
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
/*
void copyBufferTimed(size_t N)(ref CircularQueue!(AudioMessage, N) queue, short[] output, size_t hnsecDelay, size_t slaveTime, double hnsecPerSample) {
	size_t framesPerBuffer = output.length;
	// there is only one path in the while loop that doesn't break
	// that is the path where all samples in the current message can be discarded
	while(true) {
		// playTime is the time the first sample in the message should be played on
		size_t playTime = queue.currentRead.masterTime + hnsecDelay;

		// when the local time is behind the time the current audio message should be played
		if (slaveTime < playTime) {
			//writefln("Localtime behind %s hnsecs of stream", playTime - slaveTime);
			// we calc how many samples of silence we need before the current audio message should be used
			size_t silenceSamples = ((cast(double)(playTime - slaveTime)) / hnsecPerSample).to!size_t;
			// when the amount of samples of silence is bigger than output buffer size
			if (silenceSamples >= framesPerBuffer) {
				//writeln("1) ", slaveTime, ", ", playTime, ", " ,silenceSamples);
				// we fill everything with silence
				output[0..framesPerBuffer] = 0;
			} else {
				//writeln("2) ", slaveTime, ", ", playTime, ", " ,silenceSamples);
				// otherwise we fill ouput with partial silence and partial audio
				output[0..silenceSamples] = 0;
				output[silenceSamples..$] = queue.currentRead.buffer[0..framesPerBuffer - silenceSamples];
			}
			// and break the while loop
			break;
		} else {
			//writefln("Localtime ahead %s hnsecs of stream", slaveTime - playTime);
			// otherwise, we calculate how many samples in the current message can be discarded
			size_t skipSamples = ((cast(double)(slaveTime - playTime)) / hnsecPerSample).to!size_t;
			// when that is larger than the samples in the messages
			if (skipSamples >= queue.currentRead.buffer.length)
			{
				//writeln("3) ", slaveTime, ", ", playTime, ", " ,skipSamples);
				// we drop the message
				queue.advanceRead();
				// we check if the queue is empty
				if (queue.empty) {
					// and if so we fill with silence and break while the loop
					output[0..framesPerBuffer] = 0;
					break;
				}
				// if the queue isn't empty we continue the while loop
			} else {
				//writeln("4) ", slaveTime, ", ", playTime, ", " ,skipSamples);
				// when the amount of samples to be skipped is smaller than the amount of samples in the current message
				// we calculate how many samples are left in the audio message
				size_t samplesCopied = queue.currentRead.buffer.length - skipSamples;
				// and copy those
				output[0..samplesCopied] = queue.currentRead.buffer[skipSamples..$];
				// advance the queue
				queue.advanceRead();
				// and if the queue is not empty
				if (!queue.empty) {
					// we fill with the audio from the next message
					output[samplesCopied..$] = queue.currentRead.buffer[0..skipSamples];
				} else {
					// otherwise we fill with silence
					output[samplesCopied..$] = 0;
				}
				// and break the while loop
				break;
			}
		}
	}
}

@("copyBufferTimed")
unittest {
	CircularQueue!(AudioMessage, 2) queue;
	queue.currentWrite.buffer = [0,1,2,3,4,5];
	queue.currentWrite.masterTime = 10_000;
	queue.advanceWrite();
	short[] output = new short[6];
	size_t hnsecDelay = 500;
	size_t slaveTime = 10_500;
	double hnsecPerSample = 200;
	copyBufferTimed(queue, output, hnsecDelay, slaveTime, hnsecPerSample);
	output.shouldEqual([0,1,2,3,4,5]);

	queue.currentWrite.buffer = [1,2,3,4,5,6];
	queue.currentWrite.masterTime = 10_000;
	queue.advanceWrite();

	slaveTime = 10_700;
	copyBufferTimed(queue, output, hnsecDelay, slaveTime, hnsecPerSample);
	output.shouldEqual([2,3,4,5,6,0]);

	queue.currentWrite.buffer = [2,3,4,5,6,7];
	queue.currentWrite.masterTime = 10_000;
	queue.advanceWrite();

	slaveTime = 10_300;
	copyBufferTimed(queue, output, hnsecDelay, slaveTime, hnsecPerSample);
	output.shouldEqual([0,2,3,4,5,6]);
	slaveTime = 10_300 + 1_200;
	copyBufferTimed(queue, output, hnsecDelay, slaveTime, hnsecPerSample);
	output.shouldEqual([7,0,0,0,0,0]);
}*/

void calcStats(ref AudioMessage message, ref Stats stats, double hnsecPerSample) {
	stats.samples += 1;
	auto slaveTime = Clock.currStdTime;
	auto masterStartTime = message.startTime;
	auto masterSampleCounter = message.sampleCounter;
	auto masterTime = masterStartTime + cast(long)(masterSampleCounter * hnsecPerSample);
	assert(slaveTime > masterTime, "Clock out of sync");
	auto currentWireLatency = slaveTime - masterTime;
	stats.std.add(cast(double)currentWireLatency);
}

struct RunningStd {
	double[] values;
	uint n;
	uint idx;
	this(uint memory) {
		values = new double[memory];
	}
	auto mean() {
		uint end = min(n, values.length - 1);
		double sum = 0;
		foreach(i; 0..end)
			sum += values[i];
		return sum / end;
	}
	void add(double val) {
		if (n < values.length)
			n += 1;
		values[idx] = val;
		idx = (idx + 1) % values.length;
	}
	double getStd() {
		uint end = min(n, values.length - 1);
		double sum = 0;
		double m = mean;
		foreach(i; 0..end)
			sum += (values[i] - m)*(values[i] - m);
		if (end < 2)
			return sqrt(sum);
		return sqrt(sum / end);
	}
	double getMax() {
		uint end = min(n, values.length - 1);
		double maxValue = 0.0;
		foreach(i; 0..end)
			maxValue = max(maxValue, values[i]);
		return maxValue;
	}
}

@("RunningStd")
unittest {
	RunningStd s = RunningStd(20);
	s.getStd().shouldEqual(0.0);
	s.add(1.0);
	s.getStd().shouldEqual(0.0);
	s.add(5.0);
	s.mean.shouldEqual(3.0);
	s.add(4.0);
	s.mean.shouldApproxEqual(3.333333);
	s.add(4.0);
	s.mean.shouldApproxEqual(3.333333 + (0.666666 / 4.0));
}

struct Stats {
	RunningStd std;
	uint samples;
	this(uint memory) {
		std = RunningStd(memory);
	}
}

void copyToWithVolume(short[] source, short[] target, double volume = 0.5) {
	assert(source.length == target.length);
	foreach(idx; 0..source.length)
		target[idx] = cast(short)(source[idx] * volume);
}

void copySamples(Queue)(ref Queue queue, short[] target, size_t offset, ref long sampleCounter) {
	scope(exit) sampleCounter += target.length;

	if (queue.empty) {
		target[] = 0;
		return;
	}

	size_t framesInMessage = queue.currentRead.buffer.length;
	assert(framesInMessage == target.length,"Currently all buffers must be of same size");

	queue.currentRead.buffer[offset..$].copyToWithVolume(target[0..framesInMessage - offset], 0.5);
	if (offset == 0) {
		queue.advanceRead();
		return;
	}

	queue.advanceRead();
	if (queue.empty) {
		target[framesInMessage - offset..$] = 0;
		return;
	}

	if (queue.currentRead.sampleCounter != sampleCounter + target.length) {
		target[framesInMessage - offset..$] = 0;
		queue.advanceRead();
		return;
	}

	queue.currentRead.buffer[0..offset].copyToWithVolume(target[framesInMessage - offset..$], 0.5);
	return;
}

@("copySamples")
unittest {
  auto queue = CircularQueue!(AudioMessage, 6)();
  short[] target = new short[10];
  size_t offset = 0;
  long sampleCounter = 0;

  void reset() {
  	queue.clear();
	  queue.currentWrite = AudioMessage([0,1,2,3,4,5,6,7,8,9], 0, 0);
	  queue.advanceWrite();
	  queue.currentWrite = AudioMessage([9,8,7,6,5,4,3,2,1,0], 0, 10);
	  queue.advanceWrite();
  	offset = 0;
  	sampleCounter = 0;
  }

  reset();
  copySamples(queue, target, offset, sampleCounter);
  target.shouldEqual([0,1,2,3,4,5,6,7,8,9]);
  sampleCounter.shouldEqual(10);
  offset.shouldEqual(0);
  copySamples(queue, target, offset, sampleCounter);
  target.shouldEqual([9,8,7,6,5,4,3,2,1,0]);
  sampleCounter.shouldEqual(20);
  offset.shouldEqual(0);

  reset();
  offset = 2;
  copySamples(queue, target, offset, sampleCounter);
  target.shouldEqual([2,3,4,5,6,7,8,9,9,8]);
  sampleCounter.shouldEqual(10);
  offset.shouldEqual(2);
  copySamples(queue, target, offset, sampleCounter);
  target.shouldEqual([7,6,5,4,3,2,1,0,0,0]);
  sampleCounter.shouldEqual(20);
  offset.shouldEqual(2);
}

void advanceTillSamplesFromEnd(Queue)(ref Queue queue, long samplesToLag, long masterSampleCounter, ref long sampleCounter, ref size_t sampleOffset) {
	assert(samplesToLag < masterSampleCounter, "Lag should be bigger than current master sampleCounter");
	writefln("Setting sample lag to %s samples", samplesToLag);
	sampleOffset = samplesToLag % 64;
	samplesToLag -= sampleOffset;
	sampleCounter = masterSampleCounter - samplesToLag;
	while(samplesToLag > 0) {
		queue.advanceRead();
		samplesToLag -= 64;
	}
	assert(queue.currentRead.sampleCounter == sampleCounter, format("queue isn't wound back properly (%s != %s)",queue.currentRead.sampleCounter,sampleCounter));
	assert(!queue.empty,"queue shouldn't be empty");
	assert(!queue.full,"queue shouldn't be full");
}
class OutputPort : Port
{
	private {
		PaStream* stream;
		PaDeviceIndex idx;
		PaTime outputLatency;
		Task tid;
		uint hnsecDelay;
		double hnsecPerSample;
		long slaveStartTime;
		long sampleCounter;
		size_t sampleOffset;
		CircularQueue!(AudioMessage, 172) queue;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate, uint msDelay = 200) {
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
				port.sampleCounter += 64;
				return paContinue;
			}

			if (statusFlags == paOutputUnderflow) {
				writeln("Output Underflow");
			} else if (statusFlags == paOutputOverflow) {
				writeln("Output Overflow");
			}
			copySamples(port.queue, output, port.sampleOffset, port.sampleCounter);

			return paContinue;
		}

		tid = runTask({
			bool started = false;
			Stats stats = Stats(20);
			while(1) {
				auto raw = transport.acceptRaw();
				switch (raw.header.type) {
					case MessageType.Audio:
						readMessageInPlace(raw.data, queue.currentWrite());
						calcStats(queue.currentWrite, stats, this.hnsecPerSample);
						if (!started) {
							if (stats.samples > 500 && stats.std.getMax < this.hnsecDelay) {
								slaveStartTime = Clock.currStdTime;
								auto masterStartTime = queue.currentWrite.startTime;
								auto masterSampleCounter = queue.currentWrite.sampleCounter;
								auto masterCurrentSampleTime = masterStartTime + cast(long)(masterSampleCounter * this.hnsecPerSample);
								writefln("Current Mastertime = %s", masterCurrentSampleTime);
								writefln("Current Slavetime = %s", slaveStartTime);
								assert(slaveStartTime > masterCurrentSampleTime, "Clock out of sync");

								queue.advanceWrite();
								auto outputDeviceInfo = Pa_GetDeviceInfo(idx);
								auto outputParams = PaStreamParameters(idx, cast(int)channels, paInt16, outputDeviceInfo.defaultLowOutputLatency, null);
								auto result = Pa_OpenStream(&stream, null, &outputParams, samplerate, 64, 0, &callback, cast(void*)this );
								if (result != paNoError) {
									writeln(Pa_GetErrorText(result).fromStringz);
								} else
								{
									outputLatency = Pa_GetStreamInfo(stream).outputLatency;
									writefln("Output latency = %s", outputLatency);
								}

								// since the buffer is full, we need to advance it until it lags precisely hnsecDelay behind master
								long samplesToLag = cast(long)(this.hnsecDelay / this.hnsecPerSample);
								queue.advanceTillSamplesFromEnd(samplesToLag, masterSampleCounter, sampleCounter, sampleOffset);

								writeln("Starting output");
								Pa_StartStream(stream);
								started = true;
							} else {
								if (stats.samples > 3000) {
									assert(false, format("Network latency too high (%s mean, %s std, %s local max)", stats.std.mean, stats.std.getStd, stats.std.getMax));
								}
							}
						} 
						if ((queue.currentWrite.sampleCounter % 64000) == 0)
							writefln("Queue size = %s, wire latency (%s mean, %s std, %s local max)",queue.length, stats.std.mean, stats.std.getStd, stats.std.getMax);
						if (!queue.full)
							queue.advanceWrite();
						else if (!started) {
							queue.advanceRead();	// we can only advance the read if the stream hasn't started....
							queue.advanceWrite();
						}
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
