module roomio.stats;

import std.algorithm : min, max;
import std.math : sqrt;

struct RunningStd {
	double[] values;
	uint n;
	uint idx;
	this(uint memory) {
		values = new double[memory];
	}
	auto mean() const {
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
	double getStd() const {
		uint end = min(n, values.length - 1);
		double sum = 0;
		double m = mean;
		foreach(i; 0..end)
			sum += (values[i] - m)*(values[i] - m);
		if (end < 2)
			return sqrt(sum);
		return sqrt(sum / end);
	}
	double getMax() const {
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