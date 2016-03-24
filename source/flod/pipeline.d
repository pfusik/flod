/** Pipeline composition.
 *
 *  Authors: $(LINK2 https://github.com/epi, Adrian Matoga)
 *  Copyright: © 2016 Adrian Matoga
 *  License: $(LINK2 http://www.boost.org/users/license.html, BSL-1.0).
 */
module flod.pipeline;

import std.meta : AliasSeq;
import std.range : isDynamicArray, isInputRange;
import std.typecons : Flag, Yes, No;

import flod.meta : NonCopyable, str;
import flod.metadata;
import flod.range;
import flod.traits;

version(unittest) {
	import std.algorithm : min, max, map, copy;
	import std.conv : to;
	import std.experimental.logger : logf, errorf;
	import std.range : isInputRange, ElementType, array, take;
	import std.string : split, toLower, startsWith, endsWith;

	ulong[] inputArray;
	ulong[] outputArray;
	size_t outputIndex;

	uint filterMark(string f) {
		f = f.toLower;
		uint fm;
		if (f.startsWith("pull"))
			fm = 1;
		else if (f.startsWith("push"))
			fm = 2;
		else if (f.startsWith("alloc"))
			fm = 3;
		if (f.endsWith("pull"))
			fm |= 1 << 2;
		else if (f.endsWith("push"))
			fm |= 2 << 2;
		else if (f.endsWith("alloc"))
			fm |= 3 << 2;
		return fm;
	}

	ulong filter(string f)(ulong a) {
		enum fm = filterMark(f);
		return (a << 4) | fm;
	}

	// sources:
	struct Arg(alias T) { bool constructed = false; }

	mixin template TestStage(N...) {
		alias This = typeof(this);
		static if (is(This == A!(B, C), alias A, B, C))
			alias Stage = A;
		else static if (is(This == D!(E), alias D, E))
			alias Stage = D;
		else static if (is(This == F!G, alias F, alias G))
			alias Stage = F;
		else static if (is(This))
			alias Stage = This;
		else
			static assert(0, "don't know how to get stage from " ~ This.stringof ~ " (" ~ str!This ~ ")");

		@disable this(this);
		@disable void opAssign(typeof(this));

		// this is to ensure that construct() calls the right constructor for each stage
		this(Arg!Stage arg) { this.arg = arg; this.arg.constructed = true; }
		Arg!Stage arg;
	}

	@pullSource!ulong
	struct TestPullSource(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		size_t pull(ulong[] buf)
		{
			auto len = min(buf.length, inputArray.length);
			buf[0 .. len] = inputArray[0 .. len];
			inputArray = inputArray[len .. $];
			return len;
		}
	}

	@peekSource!ulong @tagSetter!(uint, "test.tag")
	struct TestPeekSource(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		const(ulong)[] peek(size_t n)
		{
			tag!"test.tag" = 42;
			static assert(!__traits(compiles, tag!"test.tag"()));
			auto len = min(max(n, 2909), inputArray.length);
			return inputArray[0 .. len];
		}

		void consume(size_t n) { inputArray = inputArray[n .. $]; }
	}

	@pushSource!ulong
	struct TestPushSource(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()()
		{
			while (inputArray.length) {
				auto len = min(1337, inputArray.length);
				if (sink.push(inputArray[0 .. len]) != len)
					break;
				inputArray = inputArray[len .. $];
			}
		}
	}

	@allocSource!ulong
	struct TestAllocSource(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()()
		{
			ulong[] buf;
			while (inputArray.length) {
				auto len = min(1337, inputArray.length);
				if (!sink.alloc(buf, len))
					assert(0);
				buf[0 .. len] = inputArray[0 .. len];
				if (sink.commit(len) != len)
					break;
				inputArray = inputArray[len .. $];
			}
		}
	}

	// sinks:

	@pullSink!ulong
	struct TestPullSink(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()
		{
			while (outputIndex < outputArray.length) {
				auto len = min(4157, outputArray.length - outputIndex);
				auto pd = source.pull(outputArray[outputIndex .. outputIndex + len]);
				outputIndex += pd;
				if (pd < len)
					break;
			}
		}
	}

	@peekSink!ulong
	struct TestPeekSink(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()
		{
			while (outputIndex < outputArray.length) {
				auto len = min(4157, outputArray.length - outputIndex);
				auto ib = source.peek(len);
				auto olen = min(len, ib.length, 6379);
				outputArray[outputIndex .. outputIndex + olen] = ib[0 .. olen];
				outputIndex += olen;
				source.consume(olen);
				if (olen < len)
					break;
			}
		}
	}

	@pushSink!ulong
	struct TestPushSink(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		size_t push(const(ulong)[] buf)
		{
			auto len = min(buf.length, outputArray.length - outputIndex);
			if (len) {
				outputArray[outputIndex .. outputIndex + len] = buf[0 .. len];
				outputIndex += len;
			}
			return len;
		}
	}

	@allocSink!ulong
	struct TestAllocSink(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;
		ulong[] last;

		bool alloc(ref ulong[] buf, size_t n)
		{
			if (n < outputArray.length - outputIndex)
				buf = outputArray[outputIndex .. outputIndex + n];
			else
				buf = last = new ulong[n];
			return true;
		}

		size_t commit(size_t n)
		out(result) { assert(result <= n); }
		body
		{
			if (!last) {
				outputIndex += n;
				return n;
			} else {
				auto len = min(n, outputArray.length - outputIndex);
				outputArray[outputIndex .. outputIndex + len] = last[0 .. len];
				outputIndex += len;
				return len;
			}
		}
	}

	// filter

	@peekSink!ulong @peekSource!ulong
	struct TestPeekFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		const(ulong)[] peek(size_t n)
		{
			return source.peek(n).map!(filter!"peek").array();
		}
		void consume(size_t n) { source.consume(n); }
	}

	@peekSink!ulong @pullSource!ulong
	struct TestPeekPullFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		size_t pull(ulong[] buf)
		{
			auto ib = source.peek(buf.length);
			auto len = min(ib.length, buf.length);
			ib.take(len).map!(filter!"peekPull").copy(buf);
			source.consume(len);
			return len;
		}
	}

	@peekSink!ulong @pushSource!ulong
	struct TestPeekPushFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()()
		{
			for (;;) {
				auto ib = source.peek(4096);
				auto ob = ib.map!(filter!"peekPush").array();
				source.consume(ib.length);
				if (sink.push(ob) < 4096)
					break;
			}
		}
	}

	@peekSink!ulong @allocSource!ulong
	struct TestPeekAllocFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()()
		{
			ulong[] buf;
			for (;;) {
				auto ib = source.peek(4096);
				if (!sink.alloc(buf, ib.length))
					assert(0);
				auto len = min(ib.length, buf.length);
				ib.take(len).map!(filter!"peekAlloc").copy(buf);
				source.consume(len);
				if (sink.commit(len) < 4096)
					break;
			}
		}
	}

	@pullSink!ulong @pullSource!ulong
	struct TestPullFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		size_t pull(ulong[] buf)
		{
			size_t n = source.pull(buf);
			foreach (ref b; buf[0 .. n])
				b = b.filter!"pull";
			return n;
		}
	}

	@pullSink!ulong @peekSource!ulong
	struct TestPullPeekFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		const(ulong)[] peek(size_t n)
		{
			auto buf = new ulong[n];
			size_t m = source.pull(buf[]);
			foreach (ref b; buf[0 .. m])
				b = b.filter!"pullPeek";
			return buf[0 .. m];
		}
		void consume(size_t n) {}
	}

	@pullSink!ulong @pushSource!ulong
	struct TestPullPushFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()()
		{
			for (;;) {
				ulong[4096] buf;
				auto n = source.pull(buf[]);
				foreach (ref b; buf[0 .. n])
					b = b.filter!"pullPush";
				if (sink.push(buf[0 .. n]) < 4096)
					break;
			}
		}
	}

	@pullSink!ulong @allocSource!ulong
	struct TestPullAllocFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		void run()()
		{
			for (;;) {
				ulong[] buf;
				if (!sink.alloc(buf, 4096))
					assert(0);
				auto n = source.pull(buf[]);
				foreach (ref b; buf[0 .. n])
					b = b.filter!"pullAlloc";
				if (sink.commit(n) < 4096)
					break;
			}
		}
	}

	@pushSink!ulong @pushSource!ulong
	struct TestPushFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		size_t push(const(ulong)[] buf)
		{
			return sink.push(buf.map!(filter!"push").array());
		}
	}

	@pushSink!ulong @allocSource!ulong
	struct TestPushAllocFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;

		size_t push(const(ulong)[] buf)
		out(result) { assert(result <= buf.length); }
		body
		{
			ulong[] ob;
			if (!sink.alloc(ob, buf.length))
				assert(0);
			auto len = min(buf.length, ob.length);
			buf.take(len).map!(filter!"pushAlloc").copy(ob);
			return sink.commit(len);
		}
	}

	@pushSink!ulong @pullSource!ulong
	struct TestPushPullFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;
		ulong[] buffer;

		size_t push(const(ulong)[] buf)
		{
			buffer ~= buf.map!(filter!"pushPull").array();
			if (yield())
				return 0;
			return buf.length;
		}

		size_t pull(ulong[] buf)
		{
			size_t n = buf.length;
			while (buffer.length < n) {
				if (yield())
					break;
			}
			size_t len = min(n, buffer.length);
			buf[0 .. len] = buffer[0 .. len];
			buffer = buffer[len .. $];
			return len;
		}
	}

	@pushSink!ulong @peekSource!ulong
	struct TestPushPeekFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;
		ulong[] buffer;

		size_t push(const(ulong)[] buf)
		{
			buffer ~= buf.map!(filter!"pushPeek").array();
			if (yield())
				return 0;
			return buf.length;
		}

		const(ulong)[] peek(size_t n)
		{
			while (buffer.length < n) {
				if (yield())
					break;
			}
			return buffer;
		}

		void consume(size_t n)
		{
			buffer = buffer[n .. $];
		}
	}

	@allocSink!ulong @allocSource!ulong
	struct TestAllocFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;
		ulong[] buf;

		bool alloc(ref ulong[] buf, size_t n)
		{
			auto r = sink.alloc(buf, n);
			this.buf = buf;
			return r;
		}

		size_t commit(size_t n)
		{
			foreach (ref b; buf[0 .. n])
				b = b.filter!"alloc";
			return sink.commit(n);
		}
	}

	@allocSink!ulong @pushSource!ulong @tagGetter!(uint, "test.tag")
	struct TestAllocPushFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;
		ulong[] buffer;

		bool alloc(ref ulong[] buf, size_t n)
		{
			buffer = buf = new ulong[n];
			return true;
		}

		size_t commit(size_t n)
		{
			size_t m = sink.push(buffer[0 .. n].map!(filter!"allocPush").array());
			buffer = buffer[m .. $];
			return m;
		}
	}

	@allocSink!ulong @pullSource!ulong
	struct TestAllocPullFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;
		ulong[] buffer;
		size_t readOffset;
		size_t writeOffset;

		bool alloc(ref ulong[] buf, size_t n)
		{
			buffer.length = writeOffset + n;
			buf = buffer[writeOffset .. $];
			return true;
		}

		size_t commit(size_t n)
		{
			foreach (ref b; buffer[writeOffset .. writeOffset + n])
				b = b.filter!"allocPull";
			writeOffset += n;
			if (yield())
				return 0;
			return n;
		}

		size_t pull(ulong[] buf)
		{
			size_t n = buf.length;
			while (writeOffset - readOffset < n) {
				if (yield())
					break;
			}
			size_t len = min(n, writeOffset - readOffset);
			buf[0 .. len] = buffer[readOffset .. readOffset + len];
			readOffset += len;
			return len;
		}
	}

	@allocSink!ulong @peekSource!ulong
	struct TestAllocPeekFilter(alias Context, A...) {
		mixin TestStage;
		mixin Context!A;
		ulong[] buffer;
		size_t readOffset;
		size_t writeOffset;

		bool alloc(ref ulong[] buf, size_t n)
		{
			buffer.length = writeOffset + n;
			buf = buffer[writeOffset .. $];
			return true;
		}

		size_t commit(size_t n)
		{
			foreach (ref b; buffer[writeOffset .. writeOffset + n])
				b = b.filter!"allocPeek";
			writeOffset += n;
			if (yield())
				return 0;
			return n;
		}

		const(ulong)[] peek(size_t n)
		{
			while (writeOffset - readOffset < n) {
				if (yield())
					break;
			}
			return buffer[readOffset .. writeOffset];
		}

		void consume(size_t n)
		{
			readOffset += n;
		}
	}

	string genStage(string filter, string suf)
	{
		import std.ascii : toUpper;
		auto cf = filter[0].toUpper ~ filter[1 .. $];
		return "pipe!Test" ~ cf ~ suf ~ "(Arg!Test" ~ cf ~ suf ~ "())";
	}

	string genChain(string filterList)
	{
		import std.algorithm : map;
		import std.array : join, split;
		auto filters = filterList.split(",");
		string midstr;
		if (filters.length > 2)
			midstr = filters[1 .. $ - 1].map!(f => "." ~ genStage(f, "Filter")).join;
		return genStage(filters[0], "Source")
			~ midstr
			~ "." ~ genStage(filters[$ - 1], "Sink") ~ ";";
	}

	void testChain(string filterlist, R)(R r)
		if (isInputRange!R && is(ElementType!R : ulong))
	{
		auto input = r.map!(a => ulong(a)).array();
		logf("Testing %s with %d elements", filterlist, input.length);
		auto expectedOutput = input.dup;
		auto filters = filterlist.split(",");
		if (filters.length > 2) {
			foreach (filter; filters[1 .. $ - 1]) {
				auto fm = filterMark(filter);
				foreach (ref eo; expectedOutput)
					eo = (eo << 4) | fm;
			}
		}
		foreach(expectedLength; [ size_t(0), input.length / 3, input.length - 1, input.length,
			input.length + 1, input.length * 5 ]) {
			outputArray.length = expectedLength;
			outputArray[] = 0xbadc0ffee0ddf00d;
			inputArray = input;
			outputIndex = 0;
			mixin(genChain(filterlist));
			auto len = min(outputIndex, expectedLength, input.length);
			uint left = 8;
			size_t all = 0;
			if (outputIndex != min(expectedLength, input.length)) {
				errorf("Output length is %d, expected %d", outputIndex, min(expectedLength, input.length));
				assert(0);
			}
			for (size_t i = 0; i < len; i++) {
				if (expectedOutput[i] != outputArray[i]) {
					if (left > 0) {
						logf("expected[%d] != output[%d]: %x vs. %x", i, i, expectedOutput[i], outputArray[i]);
						--left;
					}
					all++;
				}
			}
			if (all > 0) {
				logf("%s", genChain(filterlist));
				logf("total: %d differences", all);
			}
			assert(all == 0);
		}
	}

	void testChain(string filterlist)()
	{
		import std.range : iota;
		testChain!filterlist(iota(0, 173447));
	}

}

struct SinkDrivenFiberScheduler {
	import core.thread : Fiber;
	Fiber fiber;
	mixin NonCopyable;

	void stop()
	{
		auto f = this.fiber;
		if (f) {
			if (f.state == Fiber.State.HOLD) {
				this.fiber = null;
				f.call();
			}
			auto x = f.state;
			assert(f.state == Fiber.State.TERM);
		}
	}

	int yield()
	{
		if (fiber is null)
			return 2;
		if (fiber.state == Fiber.State.EXEC) {
			Fiber.yield();
			return fiber is null;
		} else {
			if (fiber.state == Fiber.State.HOLD)
				fiber.call();
			return fiber.state != Fiber.State.HOLD;
		}
	}
}

mixin template Context(PL, alias Stage, size_t index, size_t driverIndex) {
	import flod.pipeline : isPassiveSink, isPassiveSource;
	@property ref PL outer()() { return PL.outer!index(this); }
	@property ref auto source()() { return outer.tup[index - 1]; }
	@property ref auto sink()() { return outer.tup[index + 1]; }
	@property ref auto sourceDriver()() { return outer.tup[driverIndex]; }
	static if (isPassiveSink!Stage && isPassiveSource!Stage) {
		SinkDrivenFiberScheduler _flod_scheduler;

		int yield()() { return _flod_scheduler.yield(); }
		void spawn()()
		{
			import core.thread : Fiber;
			if (!_flod_scheduler.fiber) {
				static if (__traits(compiles, &sourceDriver.run!()))
					auto runf = &sourceDriver.run!();
				else
					auto runf = &sourceDriver.run;
				_flod_scheduler.fiber = new Fiber(runf, 65536);
			}
		}
		void stop()() { _flod_scheduler.stop(); }
	}

	@property void tag(string key)(PL.Metadata.ValueType!key value)
	{
		outer.metadata.set!(key, index)(value);
	}

	@property PL.Metadata.ValueType!key get(string key)()
	{
		return outer.metadata.get!(key, index)(value);
	}
}

private void constructInPlace(T, Args...)(ref T t, auto ref Args args)
{
	debug(FlodTraceLifetime) {
		import std.experimental.logger : tracef;
		tracef("Construct at %x..%x %s with %s", &t, &t + 1, .str!T, Args.stringof);
	}
	static if (__traits(hasMember, t, "__ctor")) {
		t.__ctor(args);
	} else static if (Args.length > 0) {
		static assert(0, "Stage " ~ str!T ~ " does not have a non-trivial constructor" ~
			" but construction was requested with arguments " ~ Args.stringof);
	}
}

private struct NullPipeline {
	enum size_t length = 0;
	enum size_t driverIndex = -1;
	enum str = "";
	enum treeStr(int indent) = "";
	alias StageSeq = AliasSeq!();
	alias InstSeq = AliasSeq!();
	enum size_t[] drivers = [];
}

private struct Pipeline(alias S, SoP, A...) {
	import std.conv : to;
	alias Stage = S;
	alias Args = A;
	alias SourcePipeline = SoP;

	alias StageSeq = AliasSeq!(SourcePipeline.StageSeq, Stage);
	alias FirstStage = StageSeq[0];
	alias LastStage = StageSeq[$ - 1];

	enum bool isDriver = (isActiveSource!Stage && !isPassiveSink!Stage)
		|| (isActiveSink!Stage && !isPassiveSource!Stage);
	enum size_t driverIndex = isDriver ? index : SourcePipeline.driverIndex;
	enum size_t index = SourcePipeline.length;
	enum size_t length  = SourcePipeline.length + 1;
	enum drivers = SourcePipeline.drivers ~ driverIndex;

	enum hasSource = !is(SourcePipeline == NullPipeline);

	static if (is(Traits!LastStage.SourceElementType W))
		alias ElementType = W;

	enum str = (hasSource ? SourcePipeline.str ~ "->" : "") ~ index.to!string ~ (isDriver ? "*" : ".") ~ .str!Stage;

	SourcePipeline sourcePipeline;
	Args args;

	auto pipe(alias NextStage, NextArgs...)(auto ref NextArgs nextArgs)
	{
		alias SourceE = Traits!LastStage.SourceElementType;
		alias SinkE = Traits!NextStage.SinkElementType;
		static assert(is(SourceE == SinkE), "Incompatible element types: " ~
			.str!LastStage ~ " produces " ~ SourceE.stringof ~ ", while " ~
			.str!NextStage ~ " expects " ~ SinkE.stringof);

		static if (areCompatible!(LastStage, NextStage)) {
			auto result = pipeline!NextStage(this, nextArgs);
			static if (isSource!NextStage || isSink!FirstStage)
				return result;
			else
				result.run();
		} else {
			import std.string : capitalize;
			import flod.adapter;
			enum adapterName = Traits!LastStage.sourceMethodStr ~ Traits!NextStage.sinkMethodStr.capitalize();
			mixin(`return this.` ~ adapterName ~ `.pipe!NextStage(nextArgs);`);
		}
	}

	static struct Type(MT) {
		alias Metadata = MT;

		template IthType(size_t i) {
			alias StageType = StageSeq[i];
			alias IthType = StageType!(Context, Type, StageType, i, drivers[i]);
		}

		template StageTypeTuple(T, size_t i, Stages...) {
			static if (i >= Stages.length)
				alias Tuple = AliasSeq!();
			else {
				alias Tuple = AliasSeq!(IthType!i, StageTypeTuple!(T, i + 1, Stages).Tuple);
			}
		}

		alias Tup = StageTypeTuple!(Type, 0, StageSeq).Tuple;
		Tup tup;
		Metadata metadata;

		static ref Type outer(size_t thisIndex)(ref IthType!thisIndex thisref)
		{
			return *(cast(Type*) (cast(void*) &thisref - Type.init.tup[thisIndex].offsetof));
		}

		static if (isPeekSource!LastStage) {
			const(ElementType)[] peek()(size_t n) { return tup[index].peek(n); }
			void consume()(size_t n) { tup[index].consume(n); }
		} else static if (isPullSource!LastStage) {
			size_t pull()(ElementType[] buf) { return tup[index].pull(buf); }
		} else {
			// TODO: sink pipelines.
			void run()()
			{
				tup[driverIndex].run();
			}
		}
	}

	void construct(T)(ref T t)
	{
		static if (hasSource) {
			sourcePipeline.construct(t);
		}
		constructInPlace(t.tup[index], args);
		static if (isPassiveSink!Stage && isPassiveSource!Stage)
			t.tup[index].spawn();
	}

	static if (!isSink!FirstStage && !isSource!LastStage) {
		void run()()
		{
			alias PS = FilterTagAttributes!(0, StageSeq);
			alias MT = Metadata!PS;
			Type!MT t;
			this.construct(t);
			t.run();
		}
	}

	static if (!isSink!FirstStage && !isActiveSource!LastStage) {
		auto create()()
		{
			alias PS = FilterTagAttributes!(0, StageSeq);
			alias MT = Metadata!PS;
			Type!MT t;
			construct(t);
			return t;
		}
	}
}

private auto pipeline(alias Stage, SoP, A...)(auto ref SoP sourcePipeline, auto ref A args)
{
	return Pipeline!(Stage, SoP, A)(sourcePipeline, args);
}

private template testPipeline(P, alias test) {
	static if (is(P == Pipeline!A, A...))
		enum testPipeline = test!(P.LastStage);
	else
		enum testPipeline = false;
}

enum isPeekPipeline(P) = isDynamicArray!P || testPipeline!(P, isPeekSource);

enum isPullPipeline(P) = isInputRange!P || testPipeline!(P, isPullSource);

enum isPushPipeline(P) = testPipeline!(P, isPushSource);

enum isAllocPipeline(P) = testPipeline!(P, isAllocSource);

enum isPipeline(P) = isPushPipeline!P || isPullPipeline!P || isPeekPipeline!P || isAllocPipeline!P;

///
auto pipe(alias Stage, Args...)(auto ref Args args)
	if (isSink!Stage || isSource!Stage)
{
	static if (isSink!Stage && Args.length > 0 && isDynamicArray!(Args[0]))
		return pipeFromArray(args[0]).pipe!Stage(args[1 .. $]);
	else static if (isSink!Stage && Args.length > 0 && isInputRange!(Args[0]))
		return pipeFromInputRange(args[0]).pipe!Stage(args[1 .. $]);
	else
		return pipeline!Stage(NullPipeline(), args);
}

unittest {
	auto p1 = pipe!TestPeekSource(Arg!TestPeekSource());
	static assert(isPeekPipeline!(typeof(p1)));
	static assert(is(p1.ElementType == ulong));
	auto p2 = pipe!TestPullSource(Arg!TestPullSource());
	static assert(isPullPipeline!(typeof(p2)));
	static assert(is(p2.ElementType == ulong));
}

unittest {
	auto p1 = pipe!TestPushSource(Arg!TestPushSource());
	static assert(isPushPipeline!(typeof(p1)));
	auto p2 = pipe!TestAllocSource(Arg!TestAllocSource());
	static assert(isAllocPipeline!(typeof(p2)));
}

unittest {
	// compatible source-sink pairs
	testChain!`peek,peek`;
	testChain!`pull,pull`;
	testChain!`push,push`;
	testChain!`alloc,alloc`;
}

unittest {
	// compatible, with 1 filter
	testChain!`peek,peek,peek`;
	testChain!`peek,peekPull,pull`;
	testChain!`peek,peekPush,push`;
	testChain!`peek,peekAlloc,alloc`;
	testChain!`pull,pullPeek,peek`;
	testChain!`pull,pull,pull`;
	testChain!`pull,pullPush,push`;
	testChain!`pull,pullAlloc,alloc`;
	testChain!`push,pushPeek,peek`;
	testChain!`push,pushPull,pull`;
	testChain!`push,push,push`;
	testChain!`push,pushAlloc,alloc`;
	testChain!`alloc,allocPeek,peek`;
	testChain!`alloc,allocPull,pull`;
	testChain!`alloc,allocPush,push`;
	testChain!`alloc,alloc,alloc`;
}

unittest {
	// just one active sink at the end
	testChain!`peek,peek,peek,peek,peek`;
	testChain!`peek,peek,peekPull,pull,pull`;
	testChain!`pull,pull,pull,pull,pull`;
	testChain!`pull,pull,pullPeek,peek,peek`;
}

unittest {
	// just one active source at the beginning
	testChain!`push,push,push,push,push`;
	testChain!`push,push,pushAlloc,alloc,alloc`;
	testChain!`alloc,alloc,alloc,alloc,alloc`;
	testChain!`alloc,alloc,allocPush,push,push`;
}

unittest {
	// convert passive source to active source, longer chains
	testChain!`pull,pullPeek,peekAlloc,allocPush,push`;
	testChain!`pull,pullPeek,peekPush,pushAlloc,alloc`;
	testChain!`peek,peekPull,pullPush,pushAlloc,alloc`;
	testChain!`peek,peekPull,pullAlloc,allocPush,push`;
}

unittest {
	// convert active source to passive source at stage 2, longer passive source chain
	testChain!`push,pushPull,pull,pull,pullPeek,peek,peekPush,push,push`;
}

unittest {
	// convert active source to passive source at stage >2 (longer active source chain)
	testChain!`push,push,pushPull,pull`;
	testChain!`push,push,push,push,push,pushPull,pull`;
	testChain!`push,push,pushAlloc,alloc,alloc,allocPeek,peek`;
}

unittest {
	// multiple inverters
	testChain!`alloc,allocPeek,peekPush,pushPull,pull`;
	testChain!`alloc,alloc,alloc,allocPeek,peek,peekPush,push,pushPull,pull`;
	testChain!`alloc,alloc,allocPeek,peekPush,pushPull,pull`;
	testChain!`alloc,alloc,alloc,allocPeek,peekPush,pushPull,pullPush,push,pushAlloc,alloc,allocPush,pushPeek,peekAlloc,allocPull,pull`;
}

unittest {
	// implicit adapters, pull->push
	testChain!`pull,push`;
	testChain!`pull,push,push`;
	testChain!`pull,pushPeek,peek`;
	testChain!`pull,pushPull,pull`;
	testChain!`pull,pushAlloc,alloc`;
}

unittest {
	// implicit adapters, pull->peek
	testChain!`pull,peek`;
	testChain!`pull,peekPush,push`;
	testChain!`pull,peek,peek`;
	testChain!`pull,peekPull,pull`;
	testChain!`pull,peekAlloc,alloc`;
}

unittest {
	// implicit adapters, pull->alloc
	testChain!`pull,alloc`;
	testChain!`pull,allocPush,push`;
	testChain!`pull,allocPeek,peek`;
	testChain!`pull,allocPull,pull`;
	testChain!`pull,alloc,alloc`;
}

unittest {
	// implicit adapters, push->pull
	testChain!`push,pull`;
	testChain!`push,pullPush,push`;
	testChain!`push,pullAlloc,alloc`;
	testChain!`push,pullPeek,peek`;
	testChain!`push,pull,pull`;
}

unittest {
	// implicit adapters, push->peek
	testChain!`push,peek`;
	testChain!`push,peekPush,push`;
	testChain!`push,peekAlloc,alloc`;
	testChain!`push,peek,peek`;
	testChain!`push,peekPull,pull`;
}

unittest {
	// implicit adapters, push->alloc
	testChain!`push,alloc`;
	testChain!`push,allocPush,push`;
	testChain!`push,allocPeek,peek`;
	testChain!`push,allocPull,pull`;
	testChain!`push,alloc,alloc`;
}

unittest {
	// implicit adapters, peek->pull
	testChain!`peek,pull`;
	testChain!`peek,pullPush,push`;
	testChain!`peek,pullAlloc,alloc`;
	testChain!`peek,pullPeek,peek`;
	testChain!`peek,pull,pull`;
}

unittest {
	// implicit adapters, peek->push
	testChain!`peek,push`;
	testChain!`peek,push,push`;
	testChain!`peek,pushAlloc,alloc`;
	testChain!`peek,pushPeek,peek`;
	testChain!`peek,pushPull,pull`;
}

unittest {
	// implicit adapters, peek->alloc
	testChain!`peek,alloc`;
	testChain!`peek,allocPush,push`;
	testChain!`peek,allocPeek,peek`;
	testChain!`peek,allocPull,pull`;
	testChain!`peek,alloc,alloc`;
}

unittest {
	// implicit adapters, alloc->peek
	testChain!`alloc,peek`;
	testChain!`alloc,peekPush,push`;
	testChain!`alloc,peekAlloc,alloc`;
	testChain!`alloc,peek,peek`;
	testChain!`alloc,peekPull,pull`;
}

unittest {
	// implicit adapters, alloc->pull
	testChain!`alloc,pull`;
	testChain!`alloc,pullPush,push`;
	testChain!`alloc,pullAlloc,alloc`;
	testChain!`alloc,pullPeek,peek`;
	testChain!`alloc,pull,pull`;
}

unittest {
	// implicit adapters, alloc->push
	testChain!`alloc,push`;
	testChain!`alloc,push,push`;
	testChain!`alloc,pushAlloc,alloc`;
	testChain!`alloc,pushPeek,peek`;
	testChain!`alloc,pushPull,pull`;
}

unittest {
	// implicit adapters, all in one pipeline
	testChain!`alloc,push,peek,pull,alloc,peek,push,pull,peek,alloc,pull,push,peek`;
}

unittest {
	auto array = [ 1UL, 0xdead, 6 ];
	assert(isPeekPipeline!(typeof(array)));
	outputArray.length = 4;
	outputIndex = 0;
	array.pipe!TestPeekSink(Arg!TestPeekSink());
	assert(outputArray[0 .. outputIndex] == array[]);
}

unittest {
	import std.range : iota, array, take;
	import std.algorithm : equal;
	auto r = iota(37UL, 1337);
	static assert(isPullPipeline!(typeof(r)));
	outputArray.length = 5000;
	outputIndex = 0;
	r.pipe!TestPullSink(Arg!TestPullSink());
	assert(outputArray[0 .. outputIndex] == iota(37, 1337).array());
	r = iota(55UL, 1555);
	outputArray.length = 20;
	outputIndex = 0;
	r.pipe!TestPullSink(Arg!TestPullSink());
	assert(outputArray[0 .. outputIndex] == iota(55, 1555).take(20).array());
}
