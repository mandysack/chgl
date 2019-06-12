use AggregationBuffer;
use DynamicAggregationBuffer;
use TerminationDetection;
use Time;

// TODO: Add a bulk insertion method so aggregation can be much faster!

config const workQueueMinTightSpinCount = 8;
config const workQueueMaxTightSpinCount = 1024;
config const workQueueMinVelocityForFlush = 0.1;

param WorkQueueUnlimitedAggregation = -1;
param WorkQueueNoAggregation = 0;

iter doWorkLoop(wq : WorkQueue(?workType), td : TerminationDetector) : workType {
  while !wq.isShutdown() {
    var (hasWork, workItem) = wq.getWork();
    if !hasWork {
      if wq.asyncTasks.hasTerminated() && td.hasTerminated() then break;
      chpl_task_yield();
      continue;
    }
    yield workItem;
  }
}

iter doWorkLoop(wq : WorkQueue(?workType), td : TerminationDetector, param tag : iterKind) : workType where tag == iterKind.standalone {
  coforall loc in Locales do on loc {
    var keepAlive : atomic bool;
    keepAlive.write(true);
    begin {
      var lastSize = 0;
      var time = new Timer();
      time.start();
      while true {
        if wq.asyncTasks.hasTerminated() && td.hasTerminated() { 
          keepAlive.write(false);
          break;
        }
        
        var currSize = wq.size;
        var delta = currSize - lastSize;
        var velocity = delta / time.elapsed(TimeUnits.milliseconds);
        time.clear();
        if velocity < workQueueMinVelocityForFlush {
          wq.flushLocal();
        }
        sleep(t=1, unit=TimeUnits.milliseconds);
      }
    }

    coforall tid in 1..here.maxTaskPar {
      var timer = new Timer();
      var timerRunning = false;
      label loop while keepAlive.read() {
        var (hasWork, workItem) = wq.getWork();
        if !hasWork {
          if !timerRunning {
            timer.start();
            timerRunning = true;
          }
          chpl_task_yield();
          continue;
        }
        if timerRunning {
          timerRunning = false;
          timer.stop();
        }
        yield workItem;
      }
      writeln("Task#", here.id, "-", tid, " spent ", timer.elapsed(TimeUnits.milliseconds), "ms waiting!");
    }
  }
}

// Swap will only swap the privatization ids, so it only applies to this instance.
// Will also flush the aggregation buffer
proc <=>(ref wq1 : WorkQueue, ref wq2 : WorkQueue) {
  sync {
    wq1.flush();
    wq2.flush();
  }
  wq1.pid <=> wq2.pid;
  wq1.instance <=> wq2.instance;
}

// Represents an uninitialized work queue. 
proc UninitializedWorkQueue(type workType) return new WorkQueue(workType, instance=nil, pid = -1);

pragma "always RVF"
record WorkQueue {
  type workType;
  var instance : unmanaged WorkQueueImpl(workType);
  var pid = -1;
  
  proc init(type workType, numAggregatedWork : int = WorkQueueNoAggregation) {
    this.workType = workType;
    this.instance = new unmanaged WorkQueueImpl(workType, numAggregatedWork);
    this.pid = this.instance.pid;
  }

  pragma "no doc"
  /*
    "Uninitialized" initializer
  */
  proc init(type workType, instance : unmanaged WorkQueueImpl(workType), pid : int) {
    this.workType = workType;
    this.instance = instance;
    this.pid = pid;
  }

  proc isInitialized() {
    return pid != -1;
  }

  proc _value {
    if pid == -1 then halt("WorkQueue unitialized...");
    return chpl_getPrivatizedCopy(instance.type, pid);
  }

  forwarding _value;
}

class WorkQueueImpl {
  type workType;
  var pid = -1;
  var queue = new unmanaged Bag(workType); 
  var destBuffer = UninitializedAggregator(workType);
  var dynamicDestBuffer = UninitializedDynamicAggregator(workType);
  var asyncTasks : TerminationDetector;
  var shutdownSignal : atomic bool;
  
  proc init(type workType, numAggregatedWork : int) {
    this.workType = workType;
    if numAggregatedWork == -1 {
      this.dynamicDestBuffer = new DynamicAggregator(workType);
    } else if numAggregatedWork > 0 {
      this.destBuffer = new Aggregator(workType, numAggregatedWork);
    }
    this.asyncTasks = new TerminationDetector(0);
    this.complete();
    this.pid = _newPrivatizedClass(_to_unmanaged(this));
  }

  proc init(other, pid) {
    this.workType = other.workType;
    this.pid = pid;
    this.destBuffer = other.destBuffer;
    this.dynamicDestBuffer = other.dynamicDestBuffer;
    this.asyncTasks = other.asyncTasks;
  }
  
  proc globalSize {
    var sz = 0;
    coforall loc in Locales with (+ reduce sz) do on loc {
      sz += getPrivatizedInstance().size;
    }
    return sz;
  }

  proc size return queue.size;

  proc dsiPrivatize(pid) {
    return new unmanaged WorkQueueImpl(this, pid);
  }

  proc dsiGetPrivatizeData() {
    return pid;
  }

  inline proc getPrivatizedInstance() {
    return chpl_getPrivatizedCopy(this.type, pid);
  }
  
  proc shutdown() {
    coforall loc in Locales do on loc {
      getPrivatizedInstance().shutdownSignal.write(true);
    }
  }

  proc isShutdown() return shutdownSignal.read();

  proc addWork(work : workType, loc : locale) {
    addWork(work, loc.id);
  }

  proc addWork(work : workType, locid = here.id) {
    if isShutdown() then halt("Attempted to 'addWork' on shutdown WorkQueue!");
    if locid != here.id {
      if destBuffer.isInitialized() {
        var buffer = destBuffer.aggregate(work, locid);
        if buffer != nil {
          // TODO: Profile if we need to fetch 'pid' in local variable
          // to avoid communications...
          asyncTasks.started(1);
          begin with (in buffer) on Locales[locid] {
            var arr = buffer.getArray();
            var _this = getPrivatizedInstance();
            buffer.done();
            local do _this.queue.add(arr);
            _this.asyncTasks.finished(1);
          }
        }
        return;
      } else if dynamicDestBuffer.isInitialized() {
        dynamicDestBuffer.aggregate(work, locid);
        return;
      } else {
        on Locales[locid] {
          local do getPrivatizedInstance().queue.add(work);
        }
        return;
      }
    }

    local do queue.add(work);
  }
    
  proc getWork() : (bool, workType) {
    var retval : (bool, workType);
    local do retval = queue.remove();
    return retval;
  }

  proc isEmpty() return this.size == 0;

  proc flushLocal() {
    if destBuffer.isInitialized() {
      for (buf, loc) in destBuffer.flushLocal() do on loc {
        var _this = getPrivatizedInstance();        
        var arr = buf.getArray();
        _this.queue.add(arr);
        buf.done();
      }
    } else if dynamicDestBuffer.isInitialized() {
      for (buf, loc) in dynamicDestBuffer.flushLocal() do on loc {
        var _this = getPrivatizedInstance();
        var arr = buf.getArray();
        _this.queue.add(arr);
        buf.done();
      }
    }
  }

  proc flush() {
    if destBuffer.isInitialized() {
      forall (buf, loc) in destBuffer.flushGlobal() do on loc {
        var _this = getPrivatizedInstance();
        var arr = buf.getArray();
        _this.queue.add(arr);
        buf.done();
      }
    } else if dynamicDestBuffer.isInitialized() {
      forall (buf, loc) in dynamicDestBuffer.flushGlobal() do on loc {
        var _this = getPrivatizedInstance();
        var arr = buf.getArray();
        _this.queue.add(arr);
        buf.done();
      }
    }
  }
}

/*
  Taken from my DistributedBag data structure
*/

/*
   Below are segment statuses, which is a way to make visible to outsiders the
   current ongoing operation. In segments, we use test-and-test-and-set spinlocks
   to allow polling for other conditions other than lock state. `sync` variables
   do not offer a means of acquiring in a non-blocking way, so this is needed to
   ensure better 'best-case' and 'average-case' phases.
*/
private param STATUS_UNLOCKED : uint = 0;
private param STATUS_ADD : uint = 1;
private param STATUS_REMOVE : uint = 2;
private param STATUS_LOOKUP : uint = 3;


/*
   The phases for operations. An operation is composed of multiple phases,
   where they make a full pass searching for ideal conditions, then less-than-ideal
   conditions; this is required to ensure maximized parallelism at all times, and
   critical to good performance, especially when a node is oversubscribed.
*/
private param ADD_BEST_CASE = 0;
private param ADD_AVERAGE_CASE = 1;
private param REMOVE_BEST_CASE = 2;
private param REMOVE_AVERAGE_CASE = 3;

config const workQueueInitialBlockSize = 1024;
config const workQueueMaxBlockSize = 1024 * 1024;


class Bag {
  type eltType;

  /*
     Helps evenly distribute and balance placement of elements in a best-effort
     round-robin approach. In the case where we have parallel enqueues or dequeues,
     they are less likely overlap with each other. Furthermore, it increases our
     chance to find our 'ideal' segment.
  */
  var startIdxEnq : chpl__processorAtomicType(uint);
  var startIdxDeq : chpl__processorAtomicType(uint);

  var maxParallelSegmentSpace = {0..#here.maxTaskPar};
  var segments : [maxParallelSegmentSpace] BagSegment(eltType);

  inline proc nextStartIdxEnq {
    return (startIdxEnq.fetchAdd(1) % here.maxTaskPar : uint) : int;
  }

  inline proc nextStartIdxDeq {
    return (startIdxDeq.fetchAdd(1) % here.maxTaskPar : uint) : int;
  }

  proc init(type eltType) {
    this.eltType = eltType;
  }

  proc deinit() {
    forall segment in segments {
      var block = segment.headBlock;
      while block != nil {
        var tmp = block;
        block = block.next;
        delete tmp;
      }
    }
  }

  // Note: Serial so runtime does not try to parallelize this
  // Serial for loop is faster when we have one task per core already in use.
  proc size {
    var sz = 0;
    forall idx in 0..#here.maxTaskPar with (+ reduce sz) { 
      sz += segments[idx].nElems.read() : int;
    }
    return sz;
  }

  proc add(elt : eltType) : bool {
    var startIdx = nextStartIdxEnq : int;
    var phase = ADD_BEST_CASE;

    while true {
      select phase {
        /*
           Pass 1: Best Case

           Find a segment that is unlocked and attempt to acquire it. As we are adding
           elements, we don't care how many elements there are, just that we find
           some place to add ours.
        */
        when ADD_BEST_CASE {
          for offset in 0 .. #here.maxTaskPar {
            ref segment = segments[(startIdx + offset) % here.maxTaskPar];

            // Attempt to acquire...
            if segment.acquireWithStatus(STATUS_ADD) {
              segment.addElements(elt);
              segment.releaseStatus();
              return true;
            }
          }

          phase = ADD_AVERAGE_CASE;
        }
        /*
           Pass 2: Average Case

           Find any segment (locked or unlocked) and make an attempt to acquire it.
        */
        when ADD_AVERAGE_CASE {
          ref segment = segments[startIdx];

          while true {
            select segment.currentStatus {
              // Quick acquire...
              when STATUS_UNLOCKED do {
                if segment.acquireWithStatus(STATUS_ADD) {
                  segment.addElements(elt);
                  segment.releaseStatus();
                  return true;
                }
              }
            }
            chpl_task_yield();
          }
        }
      }
    }
    halt("0xDEADC0DE");
  }

  proc remove() : (bool, eltType) {
    var startIdx = nextStartIdxDeq;
    var idx = startIdx;
    var iterations = 0;
    var phase = REMOVE_BEST_CASE;
    var backoff = 0;

    while true {
      select phase {
        /*
           Pass 1: Best Case

           Find the first bucket that is both unlocked and contains elements. This is
           extremely helpful in the case where we have a good distribution of elements
           in each segment.
        */
        when REMOVE_BEST_CASE {
          while iterations < here.maxTaskPar {
            ref segment = segments[idx];

            // Attempt to acquire...
            if !segment.isEmpty && segment.acquireWithStatus(STATUS_REMOVE) {
              var (hasElem, elem) : (bool, eltType) = segment.takeElement();
              segment.releaseStatus();

              if hasElem {
                return (hasElem, elem);
              }
            }

            iterations = iterations + 1;
            idx = (idx + 1) % here.maxTaskPar;
          }

          phase = REMOVE_AVERAGE_CASE;
        }

        /*
           Pass 2: Average Case

           Find the first bucket containing elements. We don't care if it is locked
           or unlocked this time, just that it contains elements; this handles majority
           of cases where we have elements anywhere in any segment.
        */
        when REMOVE_AVERAGE_CASE {
          while iterations < here.maxTaskPar {
            ref segment = segments[idx];

            // Attempt to acquire...
            while !segment.isEmpty {
              if segment.isUnlocked && segment.acquireWithStatus(STATUS_REMOVE) {
                var (hasElem, elem) : (bool, eltType) = segment.takeElement();
                segment.releaseStatus();

                if hasElem {
                  return (hasElem, elem);
                }
              }

              // Backoff
              chpl_task_yield();
            }

            iterations = iterations + 1;
            idx = (idx + 1) % here.maxTaskPar;
          }
          
          var retval : (bool, eltType);
          return retval;
        }
      }
      // Reset variables...
      idx = startIdx;
      iterations = 0;
      backoff = 0;
      chpl_task_yield();
    }

    halt("0xDEADC0DE");
  }
}

/*
   A segment block is an unrolled linked list node that holds a contiguous buffer
   of memory. Each segment block size *should* be a power of two, as we increase the
   size of each subsequent unroll block by twice the size. This is so that stealing
   work is faster in that majority of elements are confined to one area.

   It should be noted that the block itself is not parallel-safe, and access must be
   synchronized.
*/
pragma "no doc"
class BagSegmentBlock {
  type eltType;

  // Contiguous memory containing all elements
  var elems :  c_ptr(eltType);
  var next : unmanaged BagSegmentBlock(eltType);

  // The capacity of this block.
  var cap : int;
  // The number of occupied elements in this block.
  var size : int;

  inline proc isEmpty {
    return size == 0;
  }

  inline proc isFull {
    return size == cap;
  }

  inline proc push(elt : eltType) {
    if elems == nil {
      halt("WorkQueue Internal Error: 'elems' is nil");
    }

    if isFull {
      halt("WorkQueue Internal Error: SegmentBlock is Full");
    }

    elems[size] = elt;
    size = size + 1;
  }

  inline proc pop() : eltType {
    if elems == nil {
      halt("WorkQueue Internal Error: 'elems' is nil");
    }

    if isEmpty {
      halt("WorkQueue Internal Error: SegmentBlock is Empty");
    }

    size = size - 1;
    var elt = elems[size];
    return elt;
  }

  proc init(type eltType, capacity) {
    this.eltType = eltType;
    if capacity == 0 {
      halt("WorkQueue Internal Error: Capacity is 0...");
    }

    elems = c_malloc(eltType, capacity);
    cap = capacity;
  }

  proc init(type eltType, ptr, capacity) {
    this.eltType = eltType;
    elems = ptr;
    cap = capacity;
    size = cap;
  }

  proc deinit() {
    c_free(elems);
  }
}

/*
   A segment is, in and of itself an unrolled linked list. We maintain one per core
   to ensure maximum parallelism.
   */
pragma "no doc"
record BagSegment {
  type eltType;

  // Used as a test-and-test-and-set spinlock.
  var status : chpl__processorAtomicType(uint);

  var headBlock : unmanaged BagSegmentBlock(eltType);
  var tailBlock : unmanaged BagSegmentBlock(eltType);

  var nElems : chpl__processorAtomicType(uint);

  inline proc isEmpty {
    return nElems.read() == 0;
  }

  inline proc acquireWithStatus(newStatus) {
    return status.compareExchangeStrong(STATUS_UNLOCKED, newStatus);
  }

  // Set status with a test-and-test-and-set loop...
  inline proc acquire(newStatus) {
    while true {
      if currentStatus == STATUS_UNLOCKED && acquireWithStatus(newStatus) {
        break;
      }

      chpl_task_yield();
    }
  }

  // Set status with a test-and-test-and-set loop, but only while it is not empty...
  inline proc acquireIfNonEmpty(newStatus) {
    while !isEmpty {
      if currentStatus == STATUS_UNLOCKED && acquireWithStatus(newStatus) {
        if isEmpty {
          releaseStatus();
          return false;
        } else {
          return true;
        }
      }

      chpl_task_yield();
    }

    return false;
  }

  inline proc isUnlocked {
    return status.read() == STATUS_UNLOCKED;
  }

  inline proc currentStatus {
    return status.read();
  }

  inline proc releaseStatus() {
    status.write(STATUS_UNLOCKED);
  }

  inline proc transferElements(destPtr, n, locId = here.id) {
    var destOffset = 0;
    var srcOffset = 0;
    while destOffset < n {
      if headBlock == nil || isEmpty {
        halt(here, ": WorkQueue Internal Error: Attempted transfer ", n, " elements to ", locId, " but failed... destOffset=", destOffset);
      }

      var len = headBlock.size;
      var need = n - destOffset;
      // If the amount in this block is greater than what is left to transfer, we
      // cannot begin transferring at the beginning, so we set our offset from the end.
      if len > need {
        srcOffset = len - need;
        headBlock.size = srcOffset;
        __primitive("chpl_comm_array_put", headBlock.elems[srcOffset], locId, destPtr[destOffset], need);
        destOffset = destOffset + need;
      } else {
        srcOffset = 0;
        headBlock.size = 0;
        __primitive("chpl_comm_array_put", headBlock.elems[srcOffset], locId, destPtr[destOffset], len);
        destOffset = destOffset + len;
      }

      // Fix list if we consumed last one...
      if headBlock.isEmpty {
        var tmp = headBlock;
        headBlock = headBlock.next;
        delete tmp;

        if headBlock == nil then tailBlock = nil;
      }
    }

    nElems.sub(n : uint);
  }

  proc addElementsPtr(ptr, n, locId = here.id) {
    var offset = 0;
    while offset < n {
      var block = tailBlock;
      // Empty? Create a new one of initial size
      if block == nil then {
        tailBlock = new unmanaged BagSegmentBlock(eltType, workQueueInitialBlockSize);
        headBlock = tailBlock;
        block = tailBlock;
      }

      // Full? Create a new one double the previous size
      if block.isFull {
        block.next = new unmanaged BagSegmentBlock(eltType, min(workQueueMaxBlockSize, block.cap * 2));
        tailBlock = block.next;
        block = block.next;
      }

      var nLeft = n - offset;
      var nSpace = block.cap - block.size;
      var nFill = min(nLeft, nSpace);
      __primitive("chpl_comm_array_get", block.elems[block.size], locId, ptr[offset], nFill);
      block.size = block.size + nFill;
      offset = offset + nFill;
    }

    nElems.add(n : uint);
  }

  inline proc takeElements(n) {
    var iterations = n : int;
    var arr : [{0..#n : int}] eltType;
    var arrIdx = 0;

    for 1 .. n : int{
      if isEmpty {
        halt("WorkQueue Internal Error: Attempted to take ", n, " elements when insufficient");
      }

      if headBlock.isEmpty {
        halt("WorkQueue Internal Error: Iterating over ", n, " elements with headBlock empty but nElems is ", nElems.read());
      }

      arr[arrIdx] = headBlock.pop();
      arrIdx = arrIdx + 1;
      nElems.sub(1);

      // Fix list if we consumed last one...
      if headBlock.isEmpty {
        var tmp = headBlock;
        headBlock = headBlock.next;
        delete tmp;

        if headBlock == nil then tailBlock = nil;
      }
    }

    return arr;
  }

  inline proc takeElement() {
    if isEmpty {
      var retval : (bool, eltType);
      return retval;
    }

    if headBlock.isEmpty {
      halt("WorkQueue Internal Error: Iterating over 1 element with headBlock empty but nElems is ", nElems.read());
    }

    var elem = headBlock.pop();
    nElems.sub(1);

    // Fix list if we consumed last one...
    if headBlock.isEmpty {
      var tmp = headBlock;
      headBlock = headBlock.next;
      delete tmp;

      if headBlock == nil then tailBlock = nil;
    }

    return (true, elem);
  }

  inline proc addElements(elt : eltType) {
    var block = tailBlock;

    // Empty? Create a new one of initial size
    if block == nil then {
      tailBlock = new unmanaged BagSegmentBlock(eltType, workQueueInitialBlockSize);
      headBlock = tailBlock;
      block = tailBlock;
    }

    // Full? Create a new one double the previous size
    if block.isFull {
      block.next = new unmanaged BagSegmentBlock(eltType, min(workQueueMaxBlockSize, block.cap * 2));
      tailBlock = block.next;
      block = block.next;
    }

    block.push(elt);
    nElems.add(1);
  }

  inline proc addElements(elts) {
    for elt in elts do addElements(elt);
  }
}

proc main() {
  startVdebug("WorkQueueVisual");
  var wq = new WorkQueue(int);
  coforall loc in Locales with (in wq) do on loc {
    forall i in 1..1024 * 1024 {
      wq.addWork(locid = i % numLocales, work = i);
    }
    wq.flush();
  }

  tagVdebug("Add");

  var total : int;
  coforall loc in Locales with (in wq, + reduce total) do on loc {
    coforall tid in 1..here.maxTaskPar with (+ reduce total) {
      var (hasWork, work) = wq.getWork();
      while hasWork {
        total += work; 
        (hasWork, work) = wq.getWork();
      }
    }
  }
  tagVdebug("Sum");
  assert(total == (+ reduce (1..1024 * 1024)) * numLocales, "Expected: ", (+ reduce (1..1024 * 1024)) * numLocales, ", received: ", total);
  stopVdebug();
}
