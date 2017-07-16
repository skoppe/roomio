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
				size_t startTime = Clock.currStdTime;
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
	auto masterTime = masterStartTime + cast(size_t)(masterSampleCounter * hnsecPerSample);
	assert(slaveTime > masterTime, "Clock out of sync");
	auto currentWireLatency = slaveTime - masterTime;
	writeln(currentWireLatency);
	stats.std.add(cast(double)currentWireLatency);
}

struct RunningMean {
	size_t n;
	size_t memory;
	double mean = 0;
	this(size_t memory = 20) {
		this.memory = memory;
	}
	void add(double val) {
		if (n < memory)
			n += 1;
		mean += (val - mean) / n;
	}
}

struct RunningStd {
	RunningMean mean;
	double[] values;
	size_t idx;
	this(size_t memory) {
		mean = RunningMean(memory);
		values = new double[memory];
	}
	void add(double val) {
		mean.add(val);
		values[idx] = val;
		idx = (idx + 1) % values.length;
	}
	double getStd() {
		size_t end = min(mean.n, values.length - 1);
		double sum = 0;
		double m = mean.mean;
		foreach(i; 0..end)
			sum += (values[i] - m)*(values[i] - m);
		if (end < 2)
			return sqrt(sum);
		return sqrt(sum / end);
	}
	double getMax() {
		size_t end = min(mean.n, values.length - 1);
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
	s.mean.mean.shouldEqual(3.0);
}

struct Stats {
	RunningStd std;
	size_t samples;
	this(size_t memory) {
		std = RunningStd(memory);
	}
}

void copySamples(Queue)(ref Queue queue, short[] target, size_t offset, ref size_t sampleCounter) {
	scope(exit) sampleCounter += target.length;

	if (queue.empty) {
		target[] = 0;
		return;
	}

	size_t framesInMessage = queue.currentRead.buffer.length;
	assert(framesInMessage == target.length,"Currently all buffers must be of same size");

	target[0..framesInMessage - offset] = queue.currentRead.buffer[offset..$];
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

	target[framesInMessage - offset..$] = queue.currentRead.buffer[0..offset];
	return;
}

@("copySamples")
unittest {
  auto queue = CircularQueue!(AudioMessage, 6)();
  short[] target = new short[10];
  size_t offset = 0;
  size_t sampleCounter = 0;

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

class OutputPort : Port
{
	private {
		PaStream* stream;
		PaDeviceIndex idx;
		PaTime outputLatency;
		Task tid;
		uint hnsecDelay;
		double hnsecPerSample;
		size_t slaveStartTime;
		size_t sampleCounter;
		size_t sampleOffset;
		size_t samplesSilence;
		CircularQueue!(AudioMessage, 64) queue;
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
			//size_t slaveTime = Clock.currStdTime;

			if (statusFlags == paOutputUnderflow) {
				writeln("Output Underflow");
			} else if (statusFlags == paOutputOverflow) {
				writeln("Output Overflow");
			}
			size_t messageSamples = port.queue.currentRead.buffer.length;
			size_t messageSampleCounter = port.queue.currentRead.sampleCounter;
			//writefln("Queue length %s, slave samples %s, master samples %s", port.queue.length, port.sampleCounter, messageSampleCounter);
			if (port.samplesSilence) {
				size_t samplesSilence = min(framesPerBuffer, port.samplesSilence);
				output[0..samplesSilence] = 0;
				port.samplesSilence -= samplesSilence;
				if (samplesSilence == framesPerBuffer)
					return paContinue;
				port.sampleOffset = samplesSilence;
				output[samplesSilence..$] = port.queue.currentRead.buffer[0..messageSamples - samplesSilence];
				return paContinue;
			} else {
				copySamples(port.queue, output, port.sampleOffset, port.sampleCounter);
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
			outputLatency = Pa_GetStreamInfo(stream).outputLatency;
			writefln("Output latency = %s", outputLatency);
		}

		tid = runTask({
			bool started = false;
			Stats stats = Stats(20);
			while(1) {
				auto raw = transport.acceptRaw();
				switch (raw.header.type) {
					case MessageType.Audio:
						if (queue.full) {
							continue;
						}
						readMessageInPlace(raw.data, queue.currentWrite());
						calcStats(queue.currentWrite, stats, this.hnsecPerSample);
						if (!started) {
							if (stats.samples > 20 && stats.std.getMax < this.hnsecDelay) {
								slaveStartTime = Clock.currStdTime;
								auto masterStartTime = queue.currentWrite.startTime;
								auto masterSampleCounter = queue.currentWrite.sampleCounter;
								sampleCounter = masterSampleCounter;
								auto masterCurrentSampleTime = masterStartTime + cast(size_t)(masterSampleCounter * this.hnsecPerSample);
								writefln("Current Mastertime = %s", masterCurrentSampleTime);
								writefln("Current Slavetime = %s", slaveStartTime);
								assert(slaveStartTime > masterCurrentSampleTime, "Clock out of sync");

								auto currentWireLatency = slaveStartTime - masterCurrentSampleTime;
								auto samplesOutputLatency = cast(size_t)(this.outputLatency * this.samplerate);
								samplesSilence = cast(size_t)((this.hnsecDelay - currentWireLatency) / this.hnsecPerSample);// the amount of samples of silence to reach desired latency
								assert(samplesSilence > samplesOutputLatency, "Physical output latency too high");
								samplesSilence -= samplesOutputLatency;

								queue.advanceWrite();
								Pa_StartStream(stream);
								started = true;
							}
						} 
						if (stats.samples > 2000) {
							assert(false, format("Network latency too high (%s mean, %s std, %s local max)", stats.std.mean.mean, stats.std.getStd, stats.std.getMax));
						}
						if ((queue.currentWrite.sampleCounter % 64000) == 0)
							writefln("Queue size = %s, wire latency (%s mean, %s std, %s local max)",queue.length, stats.std.mean.mean, stats.std.getStd, stats.std.getMax);
						if (started)
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
