module roomio.queue;

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
  bool full() pure const { return incr(head) == tail; }
}