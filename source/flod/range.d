/** Convert ranges to pipelines and pipelines to ranges.
 *
 *  Authors: $(LINK2 https://github.com/epi, Adrian Matoga)
 *  Copyright: © 2016 Adrian Matoga
 *  License: $(LINK2 http://www.boost.org/users/license.html, BSL-1.0).
 */
module flod.range;

import std.range : isInputRange, isOutputRange;

import flod.pipeline : pipe, isPipeline;
import flod.traits;

package auto pipeFromArray(E)(const(E)[] array)
{
	@peekSource!E
	static struct ArraySource {
		const(E)[] array;
		this(const(E)* ptr, size_t length)
		{
			this.array = ptr[0 .. length];
		}

		const(E)[] peek()(size_t n) { return array; }
		void consume()(size_t n) { array = array[n .. $]; }
	}
	import std.stdio;

	return .pipe!ArraySource(array.ptr, array.length);
}

unittest {
	auto arr = [ 1, 2, 37, 98, 123, 12313 ];
	auto pl = arr.pipeFromArray.create();
	assert(pl.peek(1) == arr[]);
	assert(pl.peek(123) == arr[]);
	pl.consume(2);
	assert(pl.peek(23) == arr[2 .. $]);
	pl.consume(pl.peek(1).length);
	assert(pl.peek(1).length == 0);
}

package auto pipeFromInputRange(R)(R r)
	if (isInputRange!R)
{
	import std.range : ElementType;

	alias E = ElementType!R;
	@pullSource!E
	static struct RangeSource
	{
		R range;

		this(bool dummy, R range) { cast(void) dummy; this.range = range; }

		size_t pull()(E[] buf)
		{
			foreach (i, ref e; buf) {
				if (range.empty)
					return i;
				e = range.front;
				range.popFront();
			}
			return buf.length;
		}
	}

	return .pipe!RangeSource(false, r);
}

unittest {
	import std.range : iota, hasSlicing, hasLength, isInfinite;
	import flod.pipeline : isPullPipeline;

	auto r = iota(6, 12);
	static assert( hasSlicing!(typeof(r)));
	static assert( hasLength!(typeof(r)));
	static assert(!isInfinite!(typeof(r)));
	auto p = r.pipeFromInputRange;
	static assert(isPullPipeline!(typeof(p)));
	static assert(is(p.ElementType == int));
	auto pl = p.create();
	int[4] buf;
	assert(pl.pull(buf[]) == 4);
	assert(buf[] == [6, 7, 8, 9]);
	assert(pl.pull(buf[]) == 2);
	assert(buf[0 .. 2] == [10, 11]);
}

unittest {
	import std.range : repeat, hasSlicing, hasLength, isInfinite;

	auto r = repeat(0xdead);
	static assert( hasSlicing!(typeof(r)));
	static assert(!hasLength!(typeof(r)));
	static assert( isInfinite!(typeof(r)));
	auto pl = r.pipeFromInputRange.create();
	int[5] buf;
	assert(pl.pull(buf[]) == 5);
	assert(buf[] == [0xdead, 0xdead, 0xdead, 0xdead, 0xdead]);
	assert(pl.pull(new int[1234567]) == 1234567);
}

unittest {
	import std.range : generate, take, hasSlicing;

	auto r = generate({ int i = 0; return (){ return i++; }; }()).take(104);
	static assert(!hasSlicing!(typeof(r)));
	auto pl = r.pipeFromInputRange.create();
	int[5] buf;
	assert(pl.pull(buf[]) == 5);
	assert(buf[] == [0, 1, 2, 3, 4]);
	assert(pl.pull(new int[1234567]) == 99);
}

public auto copy(Pipeline, R)(auto ref Pipeline pipeline, R outputRange)
	if (isPipeline!Pipeline && isOutputRange!(R, Pipeline.ElementType))
{
	import std.range : put;

	alias E = Pipeline.ElementType;

	@pushSink!E
	static struct Copy {
		R range;

		this()(R range) { this.range = range; }

		size_t push()(const(E)[] buf)
		{
			put(range, buf);
			return buf.length;
		}
	}

	return pipeline.pipe!Copy(outputRange);
}

unittest {
	import std.array : appender;
	import std.range : iota;

	auto app = appender!(int[]);
	iota(89, 94).pipeFromInputRange.copy(app);
	assert(app.data[] == [89, 90, 91, 92, 93]);
}
