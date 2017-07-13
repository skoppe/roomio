module roomio.queue;

import roomio.testhelpers;

import core.atomic;

struct CircularQueue(Element, size_t Size) {
  private {
    Element[Size] data;
    shared size_t tail; // points to end of queue
    shared size_t head; // points to start of queue
    size_t incr(size_t pos) pure const {
      return (pos + 1) % Size;
    }
  }

  void pop(void delegate (ref Element) fun) {
    assert(!empty);
    fun(data[head]);
    atomicStore(head,incr(head));
  }

  void push(void delegate (ref Element) fun) {
    assert(!full);
    fun(data[tail]);
    atomicStore(tail,incr(tail));
  }

  bool empty() pure const { return tail == head; }
  bool full() pure const { return incr(tail) == head; }
  size_t length() pure const {
    if (tail < head)
      return tail + Size - head;
    return tail - head;
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