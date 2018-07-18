use AdjListHyperGraph;
use Generation;
use FIFOChannel;
use WorkQueue;
use TerminationDetection;
use ReplicatedVar;

/* 
  Represents 's-walk' state. We manage the current hyperedge sequence
  as well as our current neighbor.
*/
record WalkState {
  type edgeType;
  type vertexType;
  
  // The current sequences of edges that we have s-walked to.
  var sequenceDom = {0..-1};
  var sequence : [sequenceDom] edgeType;
  
  // Our current neighbor and if we are checking them.
  // Since we need to find two-hop neighbors, we need
  // to do them on the respective locale as well.
  var neighbor : vertexType;
  var checkingNeighbor : bool;
  var checkingIntersection : bool;

  proc init(other) {
    this.edgeType = other.edgeType;
    this.vertexType = other.vertexType;
    this.sequenceDom = other.sequenceDom;
    this.complete();
    this.sequence = other.sequence;
    this.neighbor = other.neighbor;
    this.checkingNeighbor = other.checkingNeighbor;
    this.checkingIntersection = other.checkingIntersection;
  }

  proc init(type edgeType, type vertexType, size = 0) {
    this.edgeType = edgeType;
    this.vertexType = vertexType;
    this.sequenceDom = {0..#size};
    this.complete();
    this.neighbor.id = -1;
  }

  inline proc append(edge : edgeType) {
    this.sequence.push_back(edge);
  }

  inline proc setNeighbor(vertex : vertexType) {
    this.neighbor = vertex;
    this.checkingNeighbor = true;
  }

  inline proc unsetNeighbor() {
    this.checkingNeighbor = false;
    this.neighbor.id = -1;
  }

  inline proc checkIntersection() {
    this.checkingIntersection = true;
  }

  inline proc checkedIntersection() {
    this.checkingIntersection = false;
  }
  
  inline proc isCheckingNeighbor() return this.checkingNeighbor;
  inline proc getNeighbor() return this.neighbor;
  inline proc isCheckingIntersection() return this.checkingIntersection;
  inline proc sequenceLength return this.sequenceDom.size;
  inline proc getTop() return this(this.sequenceLength - 1);

  inline proc hasProcessed(edge : edgeType) {
    for e in sequence do if e.id == edge.id then return true;
    return false;
  }

  inline proc this(idx : integral) ref {
    assert(idx >= 0 && idx < sequenceLength);
    return sequence[idx];
  }
}

iter walk(graph, s = 1, k = 2) {
  halt("Serial walk not implemented...");
}

// TODO: Profile iterator this nested...
iter walk(graph, s = 1, k = 2, param tag : iterKind) ref where tag == iterKind.standalone {
  type edgeType = graph._value.eDescType;
  type vertexType = graph._value.vDescType;
  var workQueue = new WorkQueue(WalkState(edgeType, vertexType)); 
  var keepAlive : [rcDomain] bool;
  var terminationDetector = new TerminationDetector();
  rcReplicate(keepAlive, true);
  
  // Insert initial states...
  forall e in graph.getEdges() with (in graph, in workQueue, in terminationDetector) {
    terminationDetector.started(graph.numNeighbors(e));
    // Iterate over neighbors
    forall v in graph.getNeighbors(e) with (in graph, in workQueue, in terminationDetector, in e) {
      var state = new WalkState(edgeType, vertexType, 1);
      state[0] = e;
      state.setNeighbor(v);
      workQueue.addWork(state, graph.getLocale(v));
    }
  }

  writeln("Added initial work to workQueue...");

  // With the queue populated, we can begin our work loop...
  // Spawn a new task to handle alerting each locale that they can stop...
  begin {
    writeln("Background task spawned, waiting for termination...");
    terminationDetector.wait(minBackoff = 1, maxBackoff = 100);
    writeln("Background task: sending termination signal...");
    rcReplicate(keepAlive, false);
  }
  
  // Begin work queue loops; a task on each locale, and then spawn up to the
  // maxmimum parallelism on each respective locales. Each of the tasks will
  // wait on the replicated 'keepAlive' flag. Each time a state is created
  // and before it is added to the workQueue, the termination detector will
  // increment the number of tasks started, and whenever a state is finished
  // it will increment the number of tasks finished...
  coforall loc in Locales with (in graph, in workQueue, in terminationDetector) do on loc {
    coforall tid in 1..here.maxTaskPar {
      var (hasState, state) : (bool, WalkState(edgeType, vertexType));
      while rcLocal(keepAlive) {
        (hasState, state) = workQueue.getWork();
        var waitingForWork = true;
        if !hasState {
          if !waitingForWork {
            writeln(here, "~", tid, ": Waiting for work...");
            waitingForWork = true;
          }
          chpl_task_yield();
          continue;
        }
        if waitingForWork {
          writeln(here, "~", tid, ": No longer waiting for work...");
          waitingForWork = false;
        }
        
        writeln(here, "~", tid, ": Processing state=", state);
        assert(state.sequenceLength <= k);
        // Process based on state...
        if state.isCheckingNeighbor() {
          var v = state.getNeighbor();
          state.unsetNeighbor();
          state.checkIntersection();
          for e in graph.getNeighbors(v) {
            if state.hasProcessed(e) then continue;
            var newState = state;
            newState.append(e);
            terminationDetector.started();
            workQueue.addWork(newState, graph.getLocale(e));
          }
          terminationDetector.finished();
        } else if state.isCheckingIntersection() {
          var (e1, e2) = (state[state.sequenceLength - 2], state[state.sequenceLength - 1]);
          // Check if it is not s-intersecting... if so, check to see if we have reached
          // a length of at least 'k' to determine if we should yield current sequence...
          var intersection = graph.intersection(e1, e2);
          if intersection.size >= s {
            if state.sequenceLength == k {
              yield state.sequence;
              terminationDetector.finished();
              continue;
            }
          } else {
            terminationDetector.finished();
            continue;
          }
          
          // Continue searching neighbors...
          state.checkedIntersection();
          terminationDetector.started(graph.numNeighbors(e2));
          for v in graph.getNeighbors(e2) {
            var newState = state;
            newState.setNeighbor(v);
            workQueue.addWork(newState, graph.getLocale(v));
          }
          terminationDetector.finished();
        } else {
          // If we are not checking intersection or a specific neighbor, we are in charge
          // setting up state for checking all other neighbors
          var e = state.getTop();
          terminationDetector.started(graph.numNeighbors(e));
          for v in graph.getNeighbors(e) {
            // TODO: Profile whether this simulates a 'move' constructor...
            var newState = state;
            newState.setNeighbor(v);
            workQueue.addWork(newState, graph.getLocale(v));
          }
          terminationDetector.finished();
        }
      }
    }
  }
}

proc main() {
  var graph = new AdjListHyperGraph(1024, 1024);
  generateErdosRenyiSMP(graph, 0.01);
  graph.removeDuplicates();
  forall w in walk(graph, s=3, k=3) do writeln(here, ": ", w);
}
