module roomio.id;

import std.uuid;
import roomio.testhelpers;

struct Id {
  private UUID uuid;
  static Id random() {
    return Id(randomUUID());
  }
  static Id test() {
    return Id("01234567-0123-0123-0123-0123456789ab");
  }
  this(UUID u) {
    this.uuid = u;
  }
  this(string u) {
    uuid = parseUUID(u);
  }
  string toString() {
    return uuid.toString();
  }
  const ubyte[16] raw() {
    return uuid.data;
  }
  bool opEquals(const Id other) const {
    return this.uuid == other.uuid;
  }
  void accept(C)(auto ref C cereal) {
    cereal.grain(uuid);
  }
}

unittest {
  auto id = Id("01234567-0123-0123-0123-0123456789ab");
  auto raw = id.cerealise;
  raw.decerealize!Id.shouldEqual(id);
}
