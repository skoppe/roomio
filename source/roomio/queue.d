module roomio.queue;

import roomio.testhelpers;

import core.atomic;

struct CircularQueue(Element, size_t Size) {
  private {
    Element[Size] data;
    shared size_t tail; // points to end of queue
    shared size_t head; // points to start of queue
    size_t incr(size_t pos, size_t amount) pure const {
      return (pos + amount) % Size;
    }
  }

  void pop(Args...)(void function (ref Element, Args) @nogc fun, Args args) @nogc {
    assert(!empty);
    fun(data[head], args);
    atomicStore(head,incr(head));
  }

  void push(Args...)(void function (ref Element, Args) fun, Args args) {
    assert(!full);
    fun(data[tail],args);
    atomicStore(tail,incr(tail));
  }

  ref Element currentRead() {
    return data[head];
  }

  void advanceRead(size_t amount = 1) {
    assert(!empty);
    atomicStore(head,incr(head, amount));
  }

  ref Element currentWrite() {
    return data[tail];
  }

  void advanceWrite(size_t amount = 1) {
    assert(!full);
    atomicStore(tail,incr(tail, amount));
  }

  bool empty() pure const { return tail == head; }
  bool full() pure const { return incr(tail, 1) == head; }
  size_t length() pure const {
    if (tail < head)
      return tail + Size - head;
    return tail - head;
  }

  void clear() {
    atomicStore(tail,head);
  }

  auto capacity() {
    return Size;
  }

  bool canWriteAhead(size_t ahead) {
    if (ahead > Size - 1)
      return false;
    size_t pos = (tail + ahead) % Size;
    return head > pos;
  }

  bool canWriteBehind(size_t behind) {
    return length > behind;
  }

  ref Element writeAhead(size_t ahead) {
    size_t pos = (tail + ahead) % Size;
    return data[pos];
  }

  ref Element writeBehind(size_t behind) {
    if (behind > tail)
      return data[tail + Size - behind];
    return data[tail - behind];
  }
}

@("CircularQueue")
unittest {
  auto queue = CircularQueue!(int, 6)();
  queue.empty.shouldBeTrue;
  queue.full.shouldBeFalse;
  
  queue.push((ref int i){ i = 1; });
  queue.empty.shouldBeFalse;
  queue.full.shouldBeFalse;
  
  queue.pop((ref int i){ i = 1; });
  queue.empty.shouldBeTrue;
  queue.full.shouldBeFalse;

  foreach(idx; 0..5) {
    queue.push((ref int i){ i = 1; });
    queue.empty.shouldBeFalse;
    if (idx < 4)
      queue.full.shouldBeFalse;
  }
  queue.full.shouldBeTrue;

  queue.pop((ref int i){ i = 1; });
  queue.empty.shouldBeFalse;
  queue.full.shouldBeFalse;

  queue.push((ref int i){ i = 1; });
  queue.empty.shouldBeFalse;
  queue.full.shouldBeTrue;

  foreach(idx; 0..5) {
    queue.pop((ref int i){ i = 1; });
    queue.full.shouldBeFalse;
    if (idx < 4)
      queue.empty.shouldBeFalse;
  }
  queue.empty.shouldBeTrue;

}

@("CircularQueue.byRef")
unittest {
  auto queue = CircularQueue!(int, 6)();
  queue.empty.shouldBeTrue;
  queue.full.shouldBeFalse;

  queue.currentWrite() = 42;
  queue.advanceWrite();
  queue.empty.shouldBeFalse;
  queue.full.shouldBeFalse;

  queue.currentRead().shouldEqual(42);
  queue.advanceRead();
  queue.empty.shouldBeTrue;
  queue.full.shouldBeFalse;
}