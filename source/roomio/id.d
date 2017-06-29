module roomio.id;

import std.uuid;
import roomio.testhelpers;
import cerealed;

@safe:

struct Id {
  private ubyte[16] _raw;
  static Id random() {
    return Id(randomUUID.data);
  }
  static Id test() @nogc {
    return Id(cast(ubyte[])[1, 35, 69, 103, 1, 35, 1, 35, 1, 35, 1, 35, 69, 103, 137, 171]);
  }
  this(ubyte[16] raw) @nogc {
    _raw = raw;
  }
  this(UUID u) @nogc {
    this._raw = u.data;
  }
  this(string u) {
    _raw = parseUUID(u).data;
  }
  const(ubyte[16]) raw() @nogc { return _raw; }
  bool opEquals(const Id other) @nogc const {
    return this._raw == other._raw;
  }
  void accept(C)(auto ref C cereal) {
    cereal.grain(_raw);
  }
}

unittest {
  auto id = Id("01234567-0123-0123-0123-0123456789ab");
  auto raw = id.cerealise;
  raw.decerealize!Id.shouldEqual(id);
}
