/** Top-level flod module. Provides the most commonly used stuff.
 *
 *  Authors: $(LINK2 https://github.com/epi, Adrian Matoga)
 *  Copyright: © 2016 Adrian Matoga
 *  License: $(LINK2 http://www.boost.org/users/license.html, BSL-1.0).
 */
module flod;

import std.stdio : File, KeepTerminator, writeln, writefln, stderr;

struct AlsaSink {
	import deimos.alsa.pcm;
	import std.string : toStringz;

	this(uint channels, uint samplesPerSec, uint bitsPerSample)
	{
		int err;
		if ((err = snd_pcm_open(&hpcm, "default".toStringz(), snd_pcm_stream_t.PLAYBACK, 0)) < 0)
			throw new Exception("Cannot open default audio device");
		if ((err = snd_pcm_set_params(
			hpcm, bitsPerSample == 8 ? snd_pcm_format_t.U8 : snd_pcm_format_t.S16_LE,
			snd_pcm_access_t.RW_INTERLEAVED,
			channels, samplesPerSec, 1, 50000)) < 0) {
			close();
			throw new Exception("Cannot set audio device params");
		}
		bytesPerSample = bitsPerSample / 8 * channels;
	}

	~this()
	{
		//close();
	}

	void close()
	{
		if (hpcm is null)
			return;
		snd_pcm_close(hpcm);
		hpcm = null;
	}

	void push(const(ubyte)[] buf)
	{
		snd_pcm_sframes_t frames = snd_pcm_writei(hpcm, buf.ptr, buf.length / bytesPerSample);
		if (frames < 0) {
			frames = snd_pcm_recover(hpcm, cast(int) frames, 0);
			if (frames < 0)
				throw new Exception("snd_pcm_writei failed");
		}
	}

private:
	snd_pcm_t* hpcm;
	int bytesPerSample;
}

auto alsaSink(uint channels, uint samplesPerSec, uint bitsPerSample)
{
	return AlsaSink(channels, samplesPerSec, bitsPerSample);
}

/* -> pull source, push sink -> */
struct MadDecoder(Source, Sink)
{
	import deimos.mad;
	Source source;
	Sink sink;
	const(void)* bufferStart = null;
	Throwable exception;

	private extern(C)
	static mad_flow input(void* data, mad_stream* stream)
	{
		auto self = cast(MadDecoder*) data;
		try {
			if (self.bufferStart !is null) {
				size_t cons = stream.this_frame - self.bufferStart;
				if (cons == 0)
					return mad_flow.STOP;
				self.source.consume(cons);
			}
			auto buf = self.source.peek(4096);
			if (!buf.length)
				return mad_flow.STOP;
			self.bufferStart = buf.ptr;
			mad_stream_buffer(stream, buf.ptr, buf.length);
			return mad_flow.CONTINUE;
		}
		catch (Throwable e) {
			self.exception = e;
			return mad_flow.BREAK;
		}
	}

	private static int scale(mad_fixed_t sample)
	{
	  /* round */
	  sample += (1L << (MAD_F_FRACBITS - 16));

	  /* clip */
	  if (sample >= MAD_F_ONE)
		sample = MAD_F_ONE - 1;
	  else if (sample < -MAD_F_ONE)
		sample = -MAD_F_ONE;

	  /* quantize */
	  return sample >> (MAD_F_FRACBITS + 1 - 16);
	}

	private extern(C)
	static mad_flow output(void* data, const(mad_header)* header, mad_pcm* pcm)
	{
		auto self = cast(MadDecoder*) data;
		uint nchannels, nsamples;
		const(mad_fixed_t)* left_ch;
		const(mad_fixed_t)* right_ch;

		nchannels = pcm.channels;
		nsamples  = pcm.length;
		left_ch   = pcm.samples[0].ptr;
		right_ch  = pcm.samples[1].ptr;

		if (nsamples > 0) {
			size_t size = short.sizeof * nchannels * nsamples;
			auto buf = new ubyte[size];
			//auto buf = self.sink.alloc(size);
			size_t i = 0;
			while (nsamples--) {
				int sample = scale(*left_ch++);
				buf[i++] = (sample >> 0) & 0xff;
				buf[i++] = (sample >> 8) & 0xff;
				if (nchannels == 2) {
					sample = scale(*right_ch++);
					buf[i++] = (sample >> 0) & 0xff;
					buf[i++] = (sample >> 8) & 0xff;
				}
			}
			self.sink.push(buf);
			//self.sink.commit(size);
		}
		return mad_flow.CONTINUE;
	}

	private extern(C)
	static mad_flow error(void* data, mad_stream* stream, mad_frame* frame)
	{
		return mad_flow.CONTINUE;
	}

	void run()
	{
		// TODO: why is this reference 0ed after mad_decoder_init?
		auto md = &this;
		mad_decoder decoder;
		mad_decoder_init(&decoder, cast(void*) md,
			&input, null /* header */, null /* filter */,
			&output, &error, null /* message */);

		/* start decoding */
		auto result = mad_decoder_run(&decoder, mad_decoder_mode.SYNC);

		/* release the decoder */
		mad_decoder_finish(&decoder);
		if (md.exception)
			throw md.exception;
	}
}

struct FromArray(T)
{
	const(T)[] array;

	/* pull source with own buffer */
	const(T[]) peek(size_t length)
	{
		import std.algorithm : min;
		return array[0 .. min(length, array.length)];
	}

	void consume(size_t length)
	{
		array = array[length .. $];
	}
}

auto fromArray(T)(const(T[]) array) { return FromArray!T(array); }

struct PullBuffer(Source, T)
{
	pragma(msg, "PullBuffer: ", typeof(Source.init).stringof, ", ", T.stringof);
	Source source;

	T[] buf;
	size_t readOffset;
	size_t peekOffset;

	const(T)[] peek(size_t size)
	{
		if (peekOffset + size > buf.length) {
			buf.length = (peekOffset + size + 4095) & ~size_t(4095);
			writefln("PullBuffer grow %d", buf.length);
		}
		if (peekOffset + size > readOffset) {
			size_t r = source.pull(buf[readOffset .. $]);
			readOffset += r;
		}
		return buf[peekOffset .. $];
	}

	void consume(size_t size)
	{
		peekOffset += size;
		if (peekOffset == buf.length) {
			peekOffset = 0;
			readOffset = 0;
		}
	}
}

template SourceDataType(Source)
{
	private import std.traits : arity, ReturnType, Parameters = ParameterTypeTuple, isDynamicArray, ForeachType, Unqual;

	static if (__traits(compiles, arity!(Source.init.pull))
	        && arity!(Source.init.pull) == 1
	        && is(ReturnType!(Source.init.pull) == size_t)
	        && isDynamicArray!(Parameters!(Source.init.pull)[0])) {
		alias SourceDataType = Unqual!(ForeachType!(Parameters!(Source.init.pull)[0]));
	} else {
		static assert(0, Sink.stringof ~ " is not a proper sink type");
	}
}

auto pullBuffer(Source, T = SourceDataType!Source)(Source source)
{
	return PullBuffer!(Source, T)(source);
}

struct PushBuffer(Sink, T)
{
	pragma(msg, "PushBuffer: ", typeof(Sink.init).stringof, ", ", T.stringof);
	Sink sink;

	T[] buf;
	size_t allocOffset;

	T[] alloc(size_t size)
	{
		if (allocOffset + size > buf.length) {
			buf.length = allocOffset + size;
			writefln("PushBuffer grow %d", buf.length);
		}
		return buf[allocOffset .. $];
	}

	void commit(size_t size)
	{
		sink.push(buf[allocOffset .. size]);
		allocOffset += size;
		if (allocOffset == buf.length)
			allocOffset = 0;
	}
}

template SinkDataType(Sink)
{
	private import std.traits : arity, ReturnType, Parameters = ParameterTypeTuple, isDynamicArray, ForeachType, Unqual;

	static if (__traits(compiles, arity!(Sink.init.push))
	        && arity!(Sink.init.push) == 1
	        && is(ReturnType!(Sink.init.push) == void)
	        && isDynamicArray!(Parameters!(Sink.init.push)[0])) {
		alias SinkDataType = Unqual!(ForeachType!(Parameters!(Sink.init.push)[0]));
	} else {
		static assert(0, Sink.stringof ~ " is not a proper sink type");
	}
}

auto pushBuffer(Sink, T = SinkDataType!Sink)(Sink sink)
{
	return PushBuffer!(Sink, T)(sink);
}

struct CompactPullBuffer(Source, T = SourceDataType!Sink)
{
	import std.exception : enforce;
	import core.sys.posix.stdlib : mkstemp;
	import core.sys.posix.unistd : close, unlink, ftruncate;
	import core.sys.posix.sys.mman : mmap, munmap, MAP_ANON, MAP_PRIVATE, MAP_FIXED, MAP_SHARED, MAP_FAILED, PROT_WRITE, PROT_READ;

	private {
		Source source;
		void* buffer;
		size_t length;
		size_t peekOffset;
		size_t readOffset;
	}

	this(Source source)
	{
		enum order = 12;
		length = size_t(1) << order;
		int fd = createFile();
		scope(exit) close(fd);
		allocate(fd);
		this.source = source;
	}

	void dispose()
	{
		if (buffer) {
			munmap(buffer, length << 1);
			buffer = null;
		}
	}

	private int createFile()
	{
		static immutable path = "/dev/shm/flod-CompactPullBuffer-XXXXXX";
		char[path.length + 1] mutablePath = path.ptr[0 .. path.length + 1];
		int fd = mkstemp(mutablePath.ptr);
		enforce(fd >= 0, "Failed to create shm file");
		scope(failure) enforce(close(fd) == 0, "Failed to close shm file");
		enforce(unlink(mutablePath.ptr) == 0, "Failed to unlink shm file " ~ mutablePath);
		enforce(ftruncate(fd, length) == 0, "Failed to set shm file size");
		return fd;
	}

	private void allocate(int fd)
	{
		void* addr = mmap(null, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		enforce(addr != MAP_FAILED, "Failed to mmap 1st part");
		scope(failure) munmap(addr, length);
		buffer = addr;
		addr = mmap(buffer + length, length, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_SHARED, fd, 0);
		if (addr != buffer + length) {
			assert(addr == MAP_FAILED);
			addr = mmap(buffer - length, length, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_SHARED, fd, 0);
			// TODO: if failed, try mmapping anonymous buf of 2 * length, then mmap the two copies inside it
			enforce(addr == buffer - length, "Failed to mmap 2nd part");
			buffer = addr;
		}
		writefln("%016x,%08x", buffer, length * 2);
	}

	const(T)[] peek(size_t size)
	{
		enforce(size <= length, "Growing buffer not implemented");
		auto buf = cast(T*) buffer;
		assert(readOffset <= peekOffset + 4096);
		while (peekOffset + size > readOffset)
			readOffset += source.pull(buf[readOffset .. readOffset]); //peekOffset + 4096]);
		assert(buf[0 .. length] == buf[length .. 2 *length]);
		stderr.writefln("%08x,%08x", peekOffset, readOffset - peekOffset);
		return buf[peekOffset .. readOffset];
	}

	void consume(size_t size)
	{
		assert(peekOffset + size <= readOffset);
		peekOffset += size;
		if (peekOffset >= length) {
			peekOffset -= length;
			readOffset -= length;
		}
		writefln("%08x %08x", peekOffset, readOffset);
	}
}

auto compactPullBuffer(Source, T = SourceDataType!Source)(Source source)
{
	return CompactPullBuffer!(Source, T)(source);
}

struct ToFile
{
	File file;

	void push(const(ubyte)[] buf)
	{
		file.rawWrite(buf[]);
	}
}

/* pull sink, push source */
struct RabbitStage
{
	import deimos.samplerate;

	SRC_STATE *state;
	int channels;
	double ratio;

	this(int type, int channels, double ratio)
	{
		int error;
		state = src_new(type, channels, &error);
		this.channels = channels;
		this.ratio = ratio;
	}

	void finalize()
	{
		src_delete(state);
	}

	void process(Source, Sink)(Source source, Sink sink)
	{
		SRC_DATA data;

		auto inbuf = source.peek(channels);
		auto outbuf = sink.alloc(channels);

		data.data_in = inbuf.ptr;
		data.data_out = outbuf.ptr;
		data.input_frames = inbuf.length / channels;
		data.output_frames = outbuf.length / channels;

		data.end_of_input = inbuf.length < channels * float.sizeof;

		data.src_ratio = ratio;

		src_process(state, &data);

		source.consume(data.input_frames_used * channels);
		sink.commit(data.output_frames_used * channels);
	}
}

struct CurlReader(Sink)
{
	Sink sink;

	import etc.c.curl;
	import std.exception : enforce;
	import std.string : toStringz;

	const(char)* url;
	Throwable e;

	this(string url)
	{
		this.url = url.toStringz();
	}

	void open(string url)
	{
		this.url = url.toStringz();
		sink.open();
	}

	private extern(C)
	static size_t mywrite(const(void)* buf, size_t ms, size_t nm, void* obj)
	{
		CurlReader* self = cast(CurlReader*) obj;
		size_t written;
		try {
			stderr.writefln("mywrite %s %s", ms, nm);
			written = self.sink.push((cast(const(ubyte)*) buf)[0 .. ms * nm]);
		} catch (Throwable e) {
			self.e = e;
		}
		return written;
	}

	void run()
	{
		CURL* curl = enforce(curl_easy_init(), "failed to init curl");
		curl_easy_setopt(curl, CurlOption.url, url);
		curl_easy_setopt(curl, CurlOption.writefunction, &mywrite);
		curl_easy_setopt(curl, CurlOption.file, &this);
		stderr.writefln("calling curl_easy_perform");
		auto err = curl_easy_perform(curl);
		if (err != CurlError.ok)
			stderr.writefln("curlerror: %s", err);
		curl_easy_cleanup(curl);
		if (e)
			throw e;
	}
}

enum isSource(T) = true;
enum isSink(T) = false;
enum isBufferedPullSource(T) = true;

// TODO: detect type of sink and itsSink
auto pushToPullBuffer(Sink, ItsSink)(Sink sink, ItsSink itsSink)
{
	return new PushToPullBuffer!(Sink, ItsSink)(sink, itsSink);
}
/+
struct InputStream(alias Comp, Type, T...)
{
	import std.typecons;
	static if (T.length) {
		Tuple!T tup;
	}

	static if (T.length) {
		this(T args)
		{
			tup = tuple(args);
		}
	}

	auto byLine(Terminator, Char = char)(KeepTerminator keepTerminator = KeepTerminator.no, Terminator terminator = '\x0a')
	{
		static struct Range
		{
			Type source;
			bool keep;
			Terminator term;
			this(bool keep, Terminator term, T r)
			{
				static if (T.length > 0)
					source = Type(r);
				this.keep = keep;
				this.term = term;
			}
			const(Char)[] line;

			private void next()
			{
				size_t i = 0;
				alias DT = typeof(source.peek(1)[0]);
				const(DT)[] buf = source.peek(256);
				if (buf.length == 0) {
					line = null;
					return;
				}
				while (buf[i] != term) {
					i++;
					if (i >= buf.length) {
						buf = source.peek(buf.length * 2);
						if (buf.length == i) {
							line = buf[];
							return;
						}
					}
				}
				line = buf[0 .. i + 1];
			}
			@property bool empty() { return line is null; }
			void popFront()
			{
				source.consume(line.length);
				next();
			};
			@property const(Char)[] front()
			{
				if (keep)
					return line;
				if (line.length > 0 && line[$ - 1] == term)
					return line[0 .. $ - 1];
				return line;
			}
		}
		auto r = Range(keepTerminator == KeepTerminator.yes, terminator, tup.expand);
		r.next();
		return r;
	}
}


import std.traits : isCallable;
auto stream(alias Comp, T...)(T args)
	if (isCallable!Comp || is(Comp) || isCallable!(Comp!T))
{
	alias Type = typeof(Comp(args));
	static if (isCallable!Comp || is(Comp)) {
		alias XComp = Comp;
	} else {
		alias XComp = Comp!T;
	}
	static if (isSource!Type && !isSink!Type)
		return InputStream!(XComp, Type, T)(args);
	else
		static assert(false);
	pragma(msg, Type.stringof);
}

unittest
{
	import std.range : take, array;
	auto testArray = "first line\nsecond line\nline without terminator";
	assert(stream!fromArray(testArray).byLine(KeepTerminator.yes, 'e').array == [
		"first line", "\nse", "cond line", "\nline", " without te", "rminator" ]);
	assert(stream!fromArray(testArray).byLine(KeepTerminator.no, 'e').array == [
		"first lin", "\ns", "cond lin", "\nlin", " without t", "rminator" ]);
	assert(stream!fromArray(testArray).byLine!(char, char)(KeepTerminator.yes).array == [
		"first line\n", "second line\n", "line without terminator" ]);
	assert(stream!fromArray(testArray).byLine!(char, char).array == [
		"first line", "second line", "line without terminator" ]);
	assert(stream!fromArray(testArray).byLine(KeepTerminator.yes, 'z').array == [
		"first line\nsecond line\nline without terminator" ]);
	foreach (c; stream!fromArray(testArray).byLine(KeepTerminator.yes, '\n'))
		c.writeln();
}
+/