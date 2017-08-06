module roomio.audio;

import roomio.port;
import roomio.id;
import roomio.transport;
import roomio.messages;
import roomio.queue;
import roomio.stats;

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

shared class InputPortOpener : Opener
{
	private {
		const(PaDeviceIndex) idx;
		const(StreamInputParameters) params;
		PaTime latency;
		Stream* stream;
		Task tid;
		bool running;
	}
	this(const(PaDeviceIndex) idx, const(StreamInputParameters) params) {
		this.idx = idx;
		this.params = params;
	}
	override void start(Transport transport)
	{
		auto inputDeviceInfo = Pa_GetDeviceInfo(idx);
		auto inputParams = PaStreamParameters(idx, cast(int)params.channels, paInt16, inputDeviceInfo.defaultLowInputLatency, null);
		auto result = Pa_OpenStream(cast(void**)&stream, &inputParams, null, params.samplerate, paFramesPerBufferUnspecified, 0, null, null );
		if (result != paNoError) {
			writeln(Pa_GetErrorText(result).fromStringz);
		} else
		{
			Pa_StartStream(cast(Stream*)stream);
			latency = Pa_GetStreamInfo(cast(Stream*)stream).inputLatency;
			running = true;
			//tid = runTask({
				short[] buffer = new short[params.packetSize];
				long sampleCounter;
				long startTime = Clock.currStdTime;
				while(running) {
					Pa_ReadStream(cast(Stream*)stream, buffer[].ptr, params.packetSize);
					transport.send(AudioMessage(startTime, sampleCounter, buffer[]));
					sampleCounter += params.packetSize;
					yield();
				}
				Pa_CloseStream(cast(Stream*)stream);
			//});
		}
	}
	override void kill() {
		running = false;
		//tid.join();
	}
}

struct StreamInputParameters {
	uint channels;
	double samplerate;
	uint packetSize;
}

class InputPort : Port
{
	private {
		PaDeviceIndex idx;
		bool running = true;
		//Task tid;
		shared(InputPortOpener) opener;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate) {
		this.idx = idx;
		super(Id.random(), PortType.Input, name, channels, samplerate);
	}
  override shared(Opener) createOpener(uint packetSize)
  {
		assert(opener is null, "Port already opened");
		opener = new shared(InputPortOpener)(idx, StreamInputParameters(channels, samplerate, packetSize));
		return opener;
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

struct Stats {
	RunningStd std;
	uint samples;
	uint inOrder, outOfOrder;
	this(uint memory) {
		std = RunningStd(memory);
		samples = 0;
	}
}

void copyToWithVolume(short[] source, short[] target, double volume = 0.5) {
	assert(source.length == target.length);
	foreach(idx; 0..source.length)
		target[idx] = cast(short)(source[idx] * volume);
}

void copySamples(Queue)(ref Queue queue, short[] target, size_t offset, ref long sampleCounter, double volume = 1.0) {
	scope(exit) sampleCounter += target.length;

	if (queue.empty) {
		target[] = 0;
		return;
	}

	size_t framesInMessage = queue.currentRead.buffer.length;
	assert(framesInMessage == target.length,"Currently all buffers must be of same size");

	queue.currentRead.buffer[offset..$].copyToWithVolume(target[0..framesInMessage - offset], volume);
	queue.currentRead.played = true;
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

	queue.currentRead.buffer[0..offset].copyToWithVolume(target[framesInMessage - offset..$], volume);
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
	  queue.currentWrite = AudioMessage(0, 0, [0,1,2,3,4,5,6,7,8,9]);
	  queue.advanceWrite();
	  queue.currentWrite = AudioMessage(0, 10, [9,8,7,6,5,4,3,2,1,0]);
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

void advanceTillSamplesFromEnd(Queue, size_t)(ref Queue queue, long samplesToLag, long masterSampleCounter, ref long sampleCounter, ref size_t sampleOffset) {
	assert(samplesToLag < masterSampleCounter, "Lag should be smaller than current master sampleCounter");
	assert(!queue.empty,"queue shouldn't be empty");

	long samplesStart = masterSampleCounter - samplesToLag;
	sampleOffset = cast(size_t)(samplesStart - queue.currentRead.sampleCounter);
	writefln("Skipping %s samples (lagging %s)", sampleOffset, samplesToLag);

	while(sampleOffset > queue.currentRead.buffer.length) {
		sampleOffset -= queue.currentRead.buffer.length;
		queue.advanceRead();
	}
	sampleCounter = queue.currentRead.sampleCounter;
	assert(!queue.empty,"queue shouldn't be empty");
	assert(!queue.full,"queue shouldn't be full");
}

@("advanceTillSamplesFromEnd")
unittest
{
	auto queue = CircularQueue!(AudioMessage, 6)();
	queue.currentWrite = AudioMessage(0, 0, [0,1,2,3,4,5,6,7,8,9]);
	queue.advanceWrite();
	queue.currentWrite = AudioMessage(0, 10, [9,8,7,6,5,4,3,2,1,0]);
	queue.advanceWrite();

	long sampleCounter;
	size_t sampleOffset;
	advanceTillSamplesFromEnd(queue, 4, 10, sampleCounter, sampleOffset);

	sampleCounter.shouldEqual(0);
	sampleOffset.shouldEqual(6);
	queue.length.shouldEqual(2);

	advanceTillSamplesFromEnd(queue, 4, 20, sampleCounter, sampleOffset);

	sampleCounter.shouldEqual(10);
	sampleOffset.shouldEqual(6);
	queue.length.shouldEqual(1);
}

AudioMessage* placeMessage(Queue)(ref Queue queue, const (ubyte[]) raw, ref long samplesReceived, long sampleSize) {
	AudioMessageHeader audioHeader;

	readMessageInPlace(raw, audioHeader);
	if (samplesReceived == 0)
		samplesReceived = audioHeader.sampleCounter;

	if (samplesReceived < audioHeader.sampleCounter)
	{
		// received later message earlier
		long samplesTooEarly = audioHeader.sampleCounter - samplesReceived;
		size_t slotsAhead = cast(size_t)(samplesTooEarly / sampleSize);
		if (!queue.canWriteAhead(slotsAhead)) {
			//samplesReceived = audioHeader.sampleCounter + sampleSize;
			return null;
		}

		queue.writeAhead(slotsAhead).played = false;
		readMessageInPlace(raw, queue.writeAhead(slotsAhead));
		samplesReceived = audioHeader.sampleCounter + sampleSize;
		AudioMessage* msg = &queue.writeAhead(slotsAhead);
		queue.advanceWrite(1 + slotsAhead);
		return msg;
  } else if (samplesReceived > audioHeader.sampleCounter)
  {
  	// received earlier message later
		long samplesTooLate = samplesReceived - audioHeader.sampleCounter;
		size_t slotsBehind = cast(size_t)(samplesTooLate / sampleSize);
		if (!queue.canWriteBehind(slotsBehind)) {
			return null;
		}

		queue.writeBehind(slotsBehind).played = false;
		readMessageInPlace(raw, queue.writeBehind(slotsBehind));
		return &queue.writeBehind(slotsBehind);
	}
	// received in correct order
	readMessageInPlace(raw, queue.currentWrite());
	queue.currentWrite.played = false;
	AudioMessage* msg = &queue.currentWrite();
	samplesReceived += sampleSize;
  queue.advanceWrite();
	return msg;
}

unittest {
	auto queue = CircularQueue!(AudioMessage, 11)();
	long samplesReceived = 0;
	queue.placeMessage(AudioMessage(0, 0,  [0,1]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 2, [2,3]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 6, [6,7]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 4, [4,5]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 8, [8,9]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 16, [16,17]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 14, [14,15]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 10, [10,11]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 18, [18,19]).serialize, samplesReceived, 2);
	queue.placeMessage(AudioMessage(0, 12, [12,13]).serialize, samplesReceived, 2);

	queue.currentRead.buffer.shouldEqual([0,1]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([2,3]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([4,5]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([6,7]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([8,9]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([10,11]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([12,13]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([14,15]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([16,17]); queue.advanceRead();
	queue.currentRead.buffer.shouldEqual([18,19]); queue.advanceRead();

	queue.empty.shouldEqual(true);
}

unittest {
	auto queue = CircularQueue!(AudioMessage, 6)();
	long samplesReceived = 0;
	long masterCounter = 0;
	void write(long masterCounter, short[] raw, in size_t line = __LINE__) {
		auto msg = queue.placeMessage(AudioMessage(0, masterCounter, raw).serialize, samplesReceived, 2);
		msg.shouldNotBeNull(__FILE__, line);
		msg.buffer.shouldEqual(raw, __FILE__, line);
	}

	auto popFront() {
		auto buf = queue.currentRead.buffer;
		queue.advanceRead();
		return buf;
	}

	write(0, [0,1]);
	write(2, [2,3]);
	write(6, [6,7]);
	write(4, [4,5]);

	popFront.shouldEqual([0,1]);
	popFront.shouldEqual([2,3]);
	popFront.shouldEqual([4,5]);

	write(12, [12,13]);
	write(8, [8,9]);

	popFront.shouldEqual([6,7]);

	write(10, [10,11]);

	popFront.shouldEqual([8,9]);
	popFront.shouldEqual([10,11]);
	
	write(18, [18,19]);
	write(16, [16,17]);
	write(14, [14,15]);

	popFront.shouldEqual([12,13]);

	popFront.shouldEqual([14,15]);
	popFront.shouldEqual([16,17]);
	popFront.shouldEqual([18,19]);

	queue.empty.shouldEqual(true);
}

unittest {
	auto queue = CircularQueue!(AudioMessage, 6)();
	long samplesReceived = 0;
	long masterCounter = 0;
	void write(long masterCounter, short[] raw, in size_t line = __LINE__) {
		auto msg = queue.placeMessage(AudioMessage(0, masterCounter, raw).serialize, samplesReceived, 2);
		msg.shouldNotBeNull(__FILE__, line);
		msg.buffer.shouldEqual(raw, __FILE__, line);
	}
	void writeFull(long masterCounter, short[] raw, in size_t line = __LINE__) {
		auto msg = queue.placeMessage(AudioMessage(0, masterCounter, raw).serialize, samplesReceived, 2);
		(msg is null).shouldBeTrue(__FILE__, line);
	}

	auto popFront() {
		auto buf = queue.currentRead.buffer;
		queue.advanceRead();
		return buf;
	}

	write(0, [0,1]);
	write(2, [2,3]);
	write(6, [6,7]);
	write(4, [4,5]);
	write(8, [8,9]);
	writeFull(12, [12,13]);

	popFront.shouldEqual([0,1]);
	popFront.shouldEqual([2,3]);
	popFront.shouldEqual([4,5]);
	popFront.shouldEqual([6,7]);

	write(10, [10,11]);

	popFront.shouldEqual([8,9]);
	popFront.shouldEqual([10,11]);
	
	write(18, [18,19]);
	write(16, [16,17]);
	write(14, [14,15]);

	popFront.shouldEqual([0,1]);

	popFront.shouldEqual([14,15]);
	popFront.shouldEqual([16,17]);
	popFront.shouldEqual([18,19]);

	queue.empty.shouldEqual(true);
}

extern(C) static int paOutputCallback(const(void)* inputBuffer, void* outputBuffer,
																			size_t framesPerBuffer,
																			const(PaStreamCallbackTimeInfo)* timeInfo,
																			PaStreamCallbackFlags statusFlags,
																			void *userData) {
	StreamState* state = cast(StreamState*)(userData);
	short[] output = (cast(short*)outputBuffer)[0..framesPerBuffer];
	if (state.queue.empty || state.queue.currentRead.played) {
		// we fill everything with silence
		output[0..framesPerBuffer] = 0;
		state.sampleCounter += state.packetSize;
		return paContinue;
	}

	if (statusFlags == paOutputUnderflow) {
		writeln("Output Underflow");
	} else if (statusFlags == paOutputOverflow) {
		writeln("Output Overflow");
	}
	copySamples(state.queue, output, state.sampleOffset, state.sampleCounter);

	return paContinue;
}

bool tryStartOutput(const StreamParameters params, ref StreamState state, ref Stats stats, ref AudioMessage msg, ref shared PortAudioOutput paOutput) {
	if (stats.samples < 500 || stats.std.getMax > params.hnsecDelay) {
		if (stats.samples > 3000) {
			assert(false, format("Network latency too high (%s mean, %s std, %s local max)", stats.std.mean, stats.std.getStd, stats.std.getMax));
		}
		return false;
	}

	long slaveStartTime = Clock.currStdTime;
	long masterStartTime = msg.startTime;
	long masterSampleCounter = msg.sampleCounter;
	long masterCurrentSampleTime = masterStartTime + cast(long)(masterSampleCounter * params.hnsecPerSample);
	writefln("Current Mastertime = %s", masterCurrentSampleTime);
	writefln("Current Slavetime = %s", slaveStartTime);
	assert(slaveStartTime > masterCurrentSampleTime, "Clock out of sync");

	state.queue.advanceRead(); //TODO: Is this still necessary
	auto outputDeviceInfo = Pa_GetDeviceInfo(paOutput.idx);
	auto outputParams = PaStreamParameters(paOutput.idx, cast(int)params.channels, paInt16, outputDeviceInfo.defaultLowOutputLatency, null);
	auto result = Pa_OpenStream(cast(void**)&paOutput.stream, null, &outputParams, params.samplerate, params.packetSize, 0, &paOutputCallback, cast(void*)&state );
	if (result != paNoError) {
		writeln(Pa_GetErrorText(result).fromStringz);
	} else
	{
		paOutput.outputLatency = Pa_GetStreamInfo(cast(Stream*)paOutput.stream).outputLatency;
		writefln("Output latency = %s", paOutput.outputLatency);
	}

	auto timestampToPlayCurrentMessage = masterCurrentSampleTime + params.hnsecDelay;
	assert(timestampToPlayCurrentMessage > slaveStartTime, "Lagtime must be larger than latency difference");
	auto hnsecsToLag = timestampToPlayCurrentMessage - slaveStartTime;
	auto samplesLatency = cast(long)(paOutput.outputLatency * params.samplerate);
	auto samplesToLag = cast(long)(hnsecsToLag / params.hnsecPerSample) - samplesLatency;

	// since the buffer is full, we need to advance it until it lags precisely hnsecDelay behind master
	state.queue.advanceTillSamplesFromEnd(samplesToLag, masterSampleCounter, state.sampleCounter, state.sampleOffset);

	writeln("Starting output");
	Pa_StartStream(cast(Stream*)paOutput.stream);
	return true;
}

static void receiveAudioThread(Transport transport, const StreamParameters params, bool delegate (ref Stats, ref StreamState state, ref AudioMessage) tryStartOutput) {
	StreamState state = StreamState(params.packetSize);
	bool started = false;
	Stats stats = Stats(20);
	long samplesReceived;
	long lastSamplesReceived;
	long interval = 5000 * params.packetSize;
	while(1) {
		auto raw = transport.acceptRaw();
		switch (raw.header.type) {
			case MessageType.Audio:
				AudioMessage* msg = state.queue.placeMessage(raw.data, samplesReceived, params.packetSize);
				if (msg is null)
					continue;

				if (lastSamplesReceived + params.packetSize == samplesReceived)
					 stats.inOrder++;
				else
					 stats.outOfOrder++;
				lastSamplesReceived = msg.sampleCounter;
				calcStats(*msg, stats, params.hnsecPerSample);

				if (!started) {
					started = tryStartOutput(stats, state, *msg);
				}
				if ((msg.sampleCounter % interval) == 0)
					writefln("Queue size = %s, wire latency (%s mean, %s std, %s local max), %s in-order, %s out-of-order",state.queue.length, stats.std.mean, stats.std.getStd, stats.std.getMax, stats.inOrder, stats.outOfOrder);
				if (state.queue.length + 1 > params.messageLag && !started) {
					state.queue.advanceRead();	// we can only advance the read if the stream hasn't started....
				}
				break;
			default: break;
		}
	}
}

struct StreamState {
	uint packetSize;
	long sampleCounter;
	size_t sampleOffset;
	CircularQueue!(AudioMessage, 128) queue;
}

struct StreamParameters {
	uint channels;
	double samplerate;
	uint hnsecDelay;
	uint packetSize;
	double hnsecPerSample;
	size_t messageLag;
	this(uint channels, double samplerate, uint hnsecDelay) {
		this.channels = channels;
		this.samplerate = samplerate;
		this.hnsecDelay = hnsecDelay;
		this.hnsecPerSample = 10_000_000 / samplerate;
	}
	this(uint channels, double samplerate, uint hnsecDelay, uint packetSize) {
		this(channels, samplerate, hnsecDelay);
		this.packetSize = packetSize;
		size_t samplesToLag = cast(size_t)(hnsecDelay / hnsecPerSample);
		messageLag = samplesToLag / packetSize;
	}
}

struct PortAudioOutput {
	PaDeviceIndex idx;
	PaStream* stream;
	PaTime outputLatency;
}

shared class OutputPortOpener : shared(Opener){
	private {
		PortAudioOutput paOutput;
		const StreamParameters params;
		Task tid;
	}
	this(PaDeviceIndex idx, const StreamParameters param) {
		this.paOutput = PortAudioOutput(idx);
		this.params = params;
	}
	override void start(Transport transport) {
		//assert(cast(size_t)(params.hnsecDelay / params.hnsecPerSample) < (state.queue.capacity * 64),"Cannot lag more than buffer");
		tid = runTask({
			receiveAudioThread(transport, params, (ref Stats stats, ref StreamState state, ref AudioMessage msg){
				return tryStartOutput(params, state, stats, msg, paOutput);
			});
		});
	}
	override void kill() {

	}
}

class OutputPort : Port
{
	private {
		PaDeviceIndex idx;
		shared(OutputPortOpener) opener;
		StreamParameters params;
	}
	this(PaDeviceIndex idx, string name, uint channels, double samplerate, uint msDelay = 200) {
		params = StreamParameters(channels, samplerate, msDelay * 10_000);
		this.idx = idx;
		super(Id.random(), PortType.Output, name, channels, samplerate);
	}
	override shared(Opener) createOpener(uint packetSize)
	{
		assert(opener is null, "Port already opened");
		opener = new shared(OutputPortOpener)(idx, StreamParameters(params.channels, params.samplerate, params.hnsecDelay, packetSize));
		return opener;
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
