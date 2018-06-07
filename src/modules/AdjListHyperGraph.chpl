/* This is the first data structure for hypergraphs in chgl.  This data
   structure is an adjacency list, where vertices and edges are in the "outer"
   distribution, and their adjacencies are in the "inner" distribution.
   Currently, the assumption is that the inner distribution of adjacencies is
   shared-memory, but it should be possible to easily change it to distributed.
   If we choose to distributed adjacency lists (neighbors), we may choose a
   threshold in the size of the adjacency list that causes the list of neighbors
   to be distributed since we do not want to distribute small neighbor lists.

   This version of the data structure started out in the SSCA2 benchmark and has
   been modified for the label propagation benchmark (both of these benchmarks
   are in the Chapel repository).  Borrowed from the chapel repository. Comes
   with Cray copyright and Apache license (see the Chapel repo).
 */

// TODO: Intents on arguments?  TODO: Graph creation routines.  More todos in
// the Gitlab issues system.  In general, all but the tiniest todos should
// become issues in Gitlab.


/*
   Some assumptions:

   1. It is assumed that push_back increases the amount of available
   memory by some factor.  The current implementation of push_back
   supports this assumption.  Making this assumption allows us not to
   worry about reallocating the array on every push_back.  If we
   wanted to have more fine-grained control over memory, we will have
   to investigate adding mechanisms to control it.
 */

module AdjListHyperGraph {
  use IO;
  use CyclicDist;
  use List;
  use Sort;
  use Search;

  config param AdjListHyperGraphBufferSize = 1024 * 1024;

  /*
    Record-Wrapped structure
  */
  record AdjListHyperGraph {
    // Instance of our AdjListHyperGraphImpl from node that created the record
    var instance;
    // Privatization Id
    var pid = -1;

    proc _value {
      if pid == -1 {
        halt("AdjListHyperGraph is uninitialized...");
      }

      return chpl_getPrivatizedCopy(instance.type, pid);
    }

    proc init(numVertices = 0, numEdges = 0, map : ?t = new DefaultDist) {
      instance = new AdjListHyperGraphImpl(numVertices, numEdges, map);
      pid = instance.pid;
    }

    forwarding _value;
  }

  pragma "default intent is ref"
  record SpinLockTATAS {
    // Profiling for contended access...
    var contentionCnt : atomic int(64);
    var _lock : atomic bool;

    inline proc acquire() {
      // Fast Path
      if _lock.testAndSet() == false {
        return;
      }

      if Debug.ALHG_PROFILE_CONTENTION {
        contentionCnt.fetchAdd(1);
      }

      // Slow Path
      while true {
        var val = _lock.read();
        if val == false && _lock.testAndSet() == false {
          break;
        }

        chpl_task_yield();
      }
    }

    inline proc release() {
      _lock.clear();
    }
  }

  /*
    NodeData: stores the neighbor list of a node.

    This record should really be private, and its functionality should be
    exposed by public functions.
  */
  class NodeData {
    type nodeIdType;
    var neighborListDom = {0..-1};
    var neighborList: [neighborListDom] nodeIdType;

    // Due to issue with qthreads, we need to keep this as an atomic and implement as a spinlock
    // TODO: Can parameterize this to use SpinLockTAS (Test & Set), SpinlockTATAS (Test & Test & Set),
    // and SyncLock (mutex)...
    var lock : SpinLockTATAS;

    //  Keeps track of whether or not the neighborList is sorted; any insertion must set this to false
    var isSorted : bool;

    // As neighborList is protected by a lock, the size would normally have to be computed in a mutually exclusive way.
    // By keeping a separate counter, it makes it fast and parallel-safe to check for the size of the neighborList.
    var neighborListSize : atomic int;

    proc init(type nodeIdType) {
      this.nodeIdType = nodeIdType;
    }

    proc init(other) {
      this.nodeIdType = other.nodeIdType;
      complete();

      on other {
        other.lock.acquire();

        this.neighborListDom = other.neighborListDom;
        this.neighborList = other.neighborList;
        this.isSorted = other.isSorted;
        this.neighborListSize.write(other.neighborListSize.read());

        other.lock.release();
      }
    }

    proc hasNeighbor(n) {
      var retval : bool;
      on this {
        lock.acquire();

        // Sort if not already
        if !isSorted {
          sort(neighborList);
          isSorted = true;
        }

        // Search to determine if it exists...
        retval = search(neighborList, n, sorted = true)[1];

        lock.release();
      }
    }

    inline proc numNeighbors {
      return neighborList.size;
    }

    /*
      This method is not parallel-safe with concurrent reads, but it is
      parallel-safe for concurrent writes.
    */
    proc addNodes(vals) {
      on this {
        lock.acquire(); // acquire lock

        neighborList.push_back(vals);
        isSorted = false;

        lock.release(); // release the lock
      }
    }

    proc readWriteThis(f) {
      on this {
        f <~> new ioLiteral("{ neighborListDom = ")
        	<~> neighborListDom
        	<~> new ioLiteral(", neighborlist = ")
        	<~> neighborList
        	<~> new ioLiteral(", lock$ = ")
        	<~> lock.read()
        	<~> new ioLiteral("(isFull: ")
        	<~> lock.read()
        	<~> new ioLiteral(") }");
      }
    }
  } // record

  proc =(ref lhs: NodeData, ref rhs: NodeData) {
    if lhs == rhs then return;

    lhs.lock.acquire();
    rhs.lock.acquire();

    lhs.neighborListDom = rhs.neighborListDom;
    lhs.neighborList = rhs.neighborList;

    rhs.lock.release();
    lhs.lock.release();
  }

  record Vertex {}
  record Edge   {}

  record Wrapper {
    type nodeType;
    type idType;
    var id: idType;


    /*
      Based on Brad's suggestion:

      https://stackoverflow.com/a/49951164/594274

      The idea is that we can call a function on the type.  In the
      cases where type is instantiated, we will know `nodeType` and
      `idType`, and we can just refer to them in our make method.
    */
    proc type make(id) {
      return new Wrapper(nodeType, idType, id);
    }
  }

  proc _cast(type t: Wrapper(?nodeType, ?idType), id) {
    return t.make(id);
  }

  proc id ( wrapper ) {
    return wrapper.id;
  }

  param BUFFER_OK = 0;
  param BUFFER_FULL = 1;

  enum DescriptorType { None, Vertex, Edge };

  record DestinationBuffer {
    type vDescType;
    type eDescType;
    var buffer : [1..AdjListHyperGraphBufferSize] (int, int, DescriptorType);
    var size : atomic int;
    var filled : atomic int;

    proc append(src, dest, srcType) : int {
      // Get our buffer slot
      var idx = size.fetchAdd(1) + 1;
      while idx > AdjListHyperGraphBufferSize {
        chpl_task_yield();
        idx = size.fetchAdd(1) + 1;
      }
      assert(idx > 0);

      // Fill our buffer slot and notify as filled...
      buffer[idx] = (src, dest, srcType);
      var nFilled = filled.fetchAdd(1) + 1;

      // Check if we filled the buffer...
      if nFilled == AdjListHyperGraphBufferSize {
        return BUFFER_FULL;
      }

      return BUFFER_OK;
    }

    proc clear() {
      buffer = (0, 0, DescriptorType.None);
      filled.write(0);
      size.write(0);
    }
  }

  /*
     Adjacency list hypergraph.

     The storage is an array of NodeDatas.  The edges array stores edges, and
     the vertices array stores vertices.  The storage is similar to a
     bidirectional bipartite graph.  Every edge has a set of vertices it
     contains, and every vertex has a set of edges it participates in.  In terms
     of matrix storage, we store CSR and CSC and the same time.  Storing
     strictly CSC or CSR would allow cutting the storage in half, but for now
     the assumption is that having the storage go both ways should allow
     optimizations of certain operations.
  */
  class AdjListHyperGraphImpl {
    var _verticesDomain; // domain of vertices
    var _edgesDomain; // domain of edges

    // Privatization idi
    var pid = -1;

    type vIndexType = index(_verticesDomain);
    type eIndexType = index(_edgesDomain);
    type vDescType = Wrapper(Vertex, vIndexType);
    type eDescType = Wrapper(Edge, eIndexType);

    var _vertices : [_verticesDomain] NodeData(eDescType);
    var _edges : [_edgesDomain] NodeData(vDescType);
    var _destBuffer : [LocaleSpace] DestinationBuffer(vDescType, eDescType);

    var _privatizedVertices = _vertices._value;
    var _privatizedEdges = _edges._value;
    var _privatizedVerticesPID = _vertices.pid;
    var _privatizedEdgesPID = _edges.pid;
    var _masterHandle : object;

    // Initialize a graph with initial domains
    proc init(numVertices = 0, numEdges = 0, map : ?t = new DefaultDist) {
      var verticesDomain = {0..#numVertices} dmapped new dmap(map);
      var edgesDomain = {0..#numEdges} dmapped new dmap(map);
      this._verticesDomain = verticesDomain;
      this._edgesDomain = edgesDomain;

      complete();

      // Fill vertices and edges with default class instances...
      forall v in _vertices do v = new NodeData(eDescType);
      forall e in _edges do e = new NodeData(vDescType);

      // Clear buffer...
      forall buf in this._destBuffer do buf.clear();
      this.pid = _newPrivatizedClass(this);
    }

    // creates an array sharing storage with the source array
    // ref x = _getArray(other.vertices._value);
    // could we just store privatized and vertices in separate types?
    // array element access privatizedVertices.dsiAccess(idx)
    // push_back won't work - Need to emulate implementation
    proc init(other, pid : int(64)) {
      var verticesDomain = other._verticesDomain;
      var edgesDomain = other._edgesDomain;
      verticesDomain.clear();
      edgesDomain.clear();
      this._verticesDomain = verticesDomain;
      this._edgesDomain = edgesDomain;

      complete();

      // Obtain privatized instance...
      if other.locale.id == 0 {
        this._masterHandle = other;
        this._privatizedVertices = other._vertices._value;
        this._privatizedEdges = other._edges._value;
      } else {
        this._masterHandle = other._masterHandle;
        var instance = this._masterHandle : this.type;
        this._privatizedVertices = instance._vertices._value;
        this._privatizedEdges = instance._edges._value;
      }
      this._privatizedVerticesPID = other._privatizedVerticesPID;
      this._privatizedEdgesPID = other._privatizedEdgesPID;

      // Clear buffer
      forall buf in this._destBuffer do buf.clear();
    }

    pragma "no doc"
    proc dsiPrivatize(pid) {
      return new AdjListHyperGraphImpl(this, pid);
    }

    pragma "no doc"
    proc dsiGetPrivatizeData() {
      return pid;
    }

    pragma "no doc"
    inline proc getPrivatizedInstance() {
      return chpl_getPrivatizedCopy(this.type, pid);
    }

    inline proc verticesDomain {
      return _getDomain(_privatizedVertices.dom);
    }

    inline proc localVerticesDomain {
      return verticesDomain.localSubdomain();
    }

    inline proc edgesDomain {
      return _getDomain(_privatizedEdges.dom);
    }

    inline proc localEdgesDomain {
      return edgesDomain.localSubdomain();
    }

    inline proc vertices {
      return _privatizedVertices;
    }

    inline proc edges {
      return _privatizedEdges;
    }

    inline proc vertex(idx) ref {
      return vertices.dsiAccess(idx);
    }

    inline proc vertex(desc : vDescType) ref {
      return vertex(desc.id);
    }

    inline proc edge(idx) ref {
      return edges.dsiAccess(idx);
    }

    inline proc edge(desc : eDescType) ref {
      return edge(desc.id);
    }

    inline proc verticesDist {
      return verticesDomain.dist;
    }

    inline proc edgesDist {
      return edgesDomain.dist;
    }

    iter getEdges(param tag : iterKind) where tag == iterKind.standalone {
      forall e in edgesDomain do yield e;
    }

    iter getEdges() {
      for e in edgesDomain do yield e;
    }

    iter getVertices(param tag : iterKind) where tag == iterKind.standalone {
      forall v in verticesDomain do yield v;
    }

    iter getVertices() {
      for v in verticesDomain do yield v;
    }

    proc numVertices {
      return verticesDomain.size;
    }

    proc numEdges {
      return edgesDomain.size;
    }

    // Note: this gets called on by a single task...
    inline proc emptyBuffer(locid, buffer) {
      on Locales[locid] {
        var localBuffer = buffer.buffer;
        var localThis = getPrivatizedInstance();
        forall (srcId, destId, srcType) in localBuffer {
          select srcType {
            when DescriptorType.Vertex {
              if !localThis.verticesDomain.member(srcId) {
                halt("Vertex out of bounds on locale #", locid, ", domain = ", localThis.verticesDomain);
              }
              ref v = localThis.vertex(srcId);
              if v.locale != here then halt("Expected ", v.locale, ", but got ", here, ", domain = ", localThis.localVerticesDomain, ", with ", (srcId, destId, srcType));
              v.addNodes(toEdge(destId));
            }
            when DescriptorType.Edge {
              if !localThis.edgesDomain.member(srcId) {
                halt("Edge out of bounds on locale #", locid, ", domain = ", localThis.edgesDomain);
              }
              ref e = localThis.edge(srcId);
              if e.locale != here then halt("Expected ", e.locale, ", but got ", here, ", domain = ", localThis.localEdgesDomain, ", with ", (srcId, destId, srcType));
              localThis.edge(srcId).addNodes(toVertex(destId));
            }
            when DescriptorType.None {
              // NOP
            }
          }
        }
      }
    }

    proc flushBuffers() {
      // Clear on all locales...
      coforall loc in Locales do on loc {
        const _this = getPrivatizedInstance();
        forall (locid, buf) in zip(LocaleSpace, _this._destBuffer) {
          emptyBuffer(locid, buf);
          buf.clear();
        }
      }
    }

    // Resize the edges array
    // This is not parallel safe AFAIK.
    // No checks are performed, and the number of edges can be increased or decreased
    proc resizeEdges(size) {
      edges.setIndices({0..(size-1)});
    }

    // Resize the vertices array
    // This is not parallel safe AFAIK.
    // No checks are performed, and the number of vertices can be increased or decreased
    proc resizeVertices(size) {
      vertices.setIndices({0..(size-1)});
    }

    proc addInclusionBuffered(v, e) {
      const vDesc = v : vDescType;
      const eDesc = e : eDescType;

      // Push on local buffers to send later...
      var vLocId = vertex(vDesc.id).locale.id;
      var eLocId = edge(eDesc.id).locale.id;
      ref vBuf =  _destBuffer[vLocId];
      ref eBuf = _destBuffer[eLocId];

      var vStatus = vBuf.append(vDesc.id, eDesc.id, DescriptorType.Vertex);
      if vStatus == BUFFER_FULL {
        emptyBuffer(vLocId, vBuf);
        vBuf.clear();
      }

      var eStatus = eBuf.append(eDesc.id, vDesc.id, DescriptorType.Edge);
      if eStatus == BUFFER_FULL {
        emptyBuffer(eLocId, eBuf);
        eBuf.clear();
      }

      if vDesc.id == 0 && vLocId != 0 then writeln(here, ": ", (vDesc.id, eDesc.id, DescriptorType.Vertex), "vDesc locale: ", vertex(vDesc.id).locale.id);
    }

    proc addInclusion(v, e) {
      const vDesc = v : vDescType;
      const eDesc = e : eDescType;

      vertex(vDesc.id).addNodes(eDesc);
      edge(eDesc.id).addNodes(vDesc);
    }

    // Runtime version
    inline proc toEdge(desc : integral) {
      return desc : eDescType;
    }

    // Bad argument...
    inline proc toEdge(desc) param {
      compilerError("toEdge(" + desc.type : string + ") is not permitted, required"
      + " 'integral' type ('int(8)', 'int(16)', 'int(32)', 'int(64)')");
    }

    // Runtime version
    inline proc toVertex(desc : integral) {
      return desc : vDescType;
    }

    // Bad argument...
    inline proc toVertex(desc) param {
      compilerError("toVertex(" + desc.type : string + ") is not permitted, required"
      + " 'integral' type ('int(8)', 'int(16)', 'int(32)', 'int(64)')");
    }

    // Obtains list of all degrees; not thread-safe if resized
    proc getVertexDegrees() {
      // The returned array is mapped over the same domain as the original
      // As well a *copy* of the domain is returned so that any modifications to
      // the original are isolated from the returned array.
      const degreeDom = verticesDomain;
      var degreeArr : [degreeDom] int(64);

      // Note: If set of vertices or its domain has changed this may result in errors
      // hence this is not entirely thread-safe yet...
      forall (degree, v) in zip(degreeArr, vertices) {
        degree = v.neighborList.size;
      }

      return degreeArr;
    }


    // Obtains list of all degrees; not thread-safe if resized
    proc getEdgeDegrees() {
      // The returned array is mapped over the same domain as the original
      // As well a *copy* of the domain is returned so that any modifications to
      // the original are isolated from the returned array.
      const degreeDom = edgesDomain;
      var degreeArr : [degreeDom] int(64);

      // Note: If set of vertices or its domain has changed this may result in errors
      // hence this is not entirely thread-safe yet...
      forall (degree, e) in zip(degreeArr, edges) {
        degree = e.neighborList.size;
      }

      return degreeArr;
    }

    // TODO: Need a better way of getting vertex... right now a lot of casting has to
    // be done and we need to return the index (from its domain) rather than the
    // vertex itself...
    iter forEachVertexDegree() : (vDescType, int(64)) {
      for (vid, v) in zip(verticesDomain, vertices) {
        yield (vid : vDescType, v.neighborList.size);
      }
    }

    iter forEachVertexDegree(param tag : iterKind) : (vDescType, int(64))
    where tag == iterKind.standalone {
      forall (vid, v) in zip(verticesDomain, vertices) {
        yield (vid : vDescType, v.neighborList.size);
      }
    }

    iter forEachEdgeDegree() : (eDescType, int(64)) {
      for (eid, e) in zip(edgesDomain, edges) {
        yield (eid : eDescType, e.neighborList.size);
      }
    }

    iter forEachEdgeDegree(param tag : iterKind) : (eDescType, int(64))
      where tag == iterKind.standalone {
        forall (eid, e) in zip(edgesDomain, edges) {
          yield (eid : eDescType, e.neighborList.size);
        }
    }

    proc vertexHasNeighbor( vertex, edge){
      //check if the neighborlist for
    }

    proc getVertexNumButterflies() {
      var butterflyDom = verticesDomain;
      var butterflyArr : [butterflyDom] int(64);
      // Note: If set of vertices or its domain has changed this may result in errors
      // hence this is not entirely thread-safe yet...
      forall (num_butterflies, v) in zip(butterflyArr, verticesDomain) {
        var dist_two_mults : [verticesDomain] int(64); //this is C[w] in the paper, which is the number of distinct distance-two paths that connect v and w
    //C[w] is equivalent to the number of edges that v and w are both connected to
          for u in vertices(v).neighborList {
	    for w in edges(u.id).neighborList {
	      if w.id != v {
	        dist_two_mults[w.id] += 1;
	      }
	    }
	  }
	for w in dist_two_mults.domain {
	  if dist_two_mults[w] > 0 {
	    //combinations(dist_two_mults[w], 2) is the number of butterflies that include vertices v and w
	    butterflyArr[v] += combinations(dist_two_mults[w], 2);
	  }
	}
      }
      return butterflyArr;
    }

    proc getInclusionNumButterflies(vertex, edge){
      var dist_two_mults : [verticesDomain] int(64); //this is C[x] in the paper
      var numButterflies = 0;
	for w in vertex.neighborList {
	    for x in edges(w.id).neighborList {
	      if vertexHasNeighbor(vertex, x.id) && x.id != vertex {//this syntax is wrong for checking if an array contains a value
	        dist_two_mults[x.id] += 1;
	      }
	    }
	  }
	for x in dist_two_mults.domain {
	  //combinations(dist_two_mults[x], 2) is the number of butterflies that include vertices v and w
	  numButterflies += combinations(dist_two_mults[x], 2);
	}
      return numButterflies;
    }

    proc getInclusionNumCaterpillars( vertex, edge ){
      return (vertex.neighborList.size - 1)*(edge.neighborList.size -1);
    }

    proc getInclusionMetamorphCoef(vertex, edge){
      var numCaterpillars = getInclusionNumCaterpillars(vertex, edge);
      if numCaterpillars != 0 then
        return getInclusionNumButterflies(vertex, edge) / getInclusionNumCaterpillars(vertex, edge);
      else
        return 0;
    }

    proc getVertexMetamorphCoefs(){
    	var vertexMetamorphCoefs = [verticesDomain] : real;
        for (vertex, coef) in (vertices, vertexMetamorphCoefs) {
          for (coef, edge) in (vertexMetamorphCoefs,vertex.neighborList){
            coef += getInclusionMetamorphCoef(vertex, edge);
          }
          coef = coef / vertex.neighborList.size;
        }
        return vertexMetamorphCoefs;
    }

    proc getEdgeMetamorphCoefs(){
    }

    proc getVerticesWithDegreeValue( value : int(64)){
    }

    proc getEdgesWithDegreeValue( value : int(64)){

    }

    proc getVertexPerDegreeMetamorphosisCoefficients(){
      var maxDegree = max(getVertexDegrees());
      var perDegreeMetamorphCoefs = [{0..maxDegree}]: real;
      var vertexMetamorphCoef = getVertexMetamorphCoefs();
      var sum = 0;
      var count = 0;
      for (degree, metaMorphCoef) in (perDegreeMetamorphCoefs.domain, perDegreeMetamorphCoefs) {
        sum = 0;
        count = 0;
        for vertex in getVerticesWithDegreeValue(degree){
          sum += vertexMetamorphCoefs[vertex];
          count += 1;
        }
        metaMorphCoef = sum / count;
      }
      return perDegreeMetamorphCoefs;
    }

    proc getEdgePerDegreeMetamorphosisCoefficients(){
    }

    proc getEdgeButterflies() {
      var butterflyDom = edgesDomain;
      var butterflyArr : [butterflyDom] int(64);
      // Note: If set of vertices or its domain has changed this may result in errors
      // hence this is not entirely thread-safe yet...
      forall (num_butterflies, e) in zip(butterflyArr, edgesDomain) {
        var dist_two_mults : [edgesDomain] int(64); //this is C[w] in the paper, which is the number of distinct distance-two paths that connect v and w
	//C[w] is equivalent to the number of edges that v and w are both connected to
          for u in edges(e).neighborList {
	    for w in vertices(u.id).neighborList {
	      if w.id != e {
	        dist_two_mults[w.id] += 1;
	      }
	    }
	  }
	for w in dist_two_mults.domain {
	  if dist_two_mults[w] >1 {
	    //combinations(dist_two_mults[w], 2) is the number of butterflies that include edges e and w
	    //num_butterflies += combinations(dist_two_mults[w], 2);
	    butterflyArr[e] += combinations(dist_two_mults[w], 2);
	  }
	}
      }
      return butterflyArr;

    }

    /*proc getVertexCaterpillars() {
      var caterpillarDom = verticesDomain;
      var caterpillarArr : [caterpillarDom] int(64);
      // Note: If set of vertices or its domain has changed this may result in errors
      // hence this is not entirely thread-safe yet...
      forall (num_caterpillar, v) in zip(caterpillarArr, verticesDomain) {
        var dist_two_mults : [verticesDomain] int(64); //this is C[w] in the paper, which is the number of distinct distance-two paths that connect v and w
	//C[w] is equivalent to the number of edges that v and w are both connected to
          for u in vertices(v).neighborList {
	    for w in edges(u.id).neighborList {
	      if w.id != v {
	        dist_two_mults[w.id] += 1;
		dist_two_mults[v] += 1; //if this is added then all caterpillars including this vertex will be included in the count
	      }
	    }
	  }
	for w in dist_two_mults.domain {
	  if dist_two_mults[w] >1 {
	    //combinations(dist_two_mults[w], 2) is the number of butterflies that include edges e and w
	    //num_butterflies += combinations(dist_two_mults[w], 2);
	    caterpillarArr[v] = + reduce dist_two_mults;
	  }
	}
      }
      return  caterpillarArr;
    }

    proc getEdgeCaterpillars() {
      var caterpillarDom = edgesDomain;
      var caterpillarArr : [caterpillarDom] int(64);
      // Note: If set of edges or its domain has changed this may result in errors
      // hence this is not entirely thread-safe yet...
      forall (num_caterpillars, e) in zip(caterpillarArr, edgesDomain) {
        var dist_two_mults : [edgesDomain] int(64); //this is C[w] in the paper, which is the number of distinct distance-two paths that connect v and w
	//C[w] is equivalent to the number of edges that v and w are both connected to
          for u in edges(e).neighborList {
	    for w in vertices(u.id).neighborList {
	      if w.id != e {
	        dist_two_mults[w.id] += 1;
		dist_two_mults[e] += 1; //if this is added then all caterpillars including this edge will be included in the count
	      }
	    }
	  }
	for w in dist_two_mults.domain {
	  if dist_two_mults[w] >1 {
	    //combinations(dist_two_mults[w], 2) is the number of butterflies that include edges e and w
	    //num_butterflies += combinations(dist_two_mults[w], 2);
	    caterpillarArr[e] = + reduce dist_two_mults;
	  }
	}
      }
      return caterpillarArr;

    }*/

    iter neighbors(e : eDescType, param tag : iterKind) ref
      where tag == iterKind.standalone {
      forall v in edges[e.id].neighborList do yield v;
    }

    iter neighbors(v : vDescType) ref {
      for e in vertices[v.id].neighborList do yield e;
    }

    iter neighbors(v : vDescType, param tag : iterKind) ref
      where tag == iterKind.standalone {
      forall e in vertices[v.id].neighborList do yield e;
    }

    // Bad argument
    iter neighbors(arg) {
      compilerError("neighbors(" + arg.type : string + ") not supported, "
      + "argument must be of type " + vDescType : string + " or " + eDescType : string);
    }

    // Bad Argument
    iter neighbors(arg, param tag : iterKind) where tag == iterKind.standalone {
      compilerError("neighbors(" + arg.type : string + ") not supported, "
      + "argument must be of type " + vDescType : string + " or " + eDescType : string);
    }

    // TODO: for something in graph do ...
    iter these() {

    }

    // TODO: forall something in graph do ...
    iter these(param tag : iterKind) where tag == iterKind.standalone {

    }

    // TODO: graph[something] = somethingElse;
    // TODO: Make return ref, const-ref, or by-value versions?
    proc this() {

    }
  } // class Graph

  module Debug {
    // Determines whether or not we profile for contention...
    config param ALHG_PROFILE_CONTENTION : bool;
    // L.J: Keeps track of amount of *potential* contended accesses. It is not absolute
    // as we check to see if the lock is held prior to attempting to acquire it.
    var contentionCnt : atomic int;

    inline proc contentionCheck(ref lock : atomic bool) where ALHG_PROFILE_CONTENTION {
      if lock.read() {
        contentionCnt.fetchAdd(1);
      }
    }

    inline proc contentionCheck(ref lock : atomic bool) where !ALHG_PROFILE_CONTENTION {
      // NOP
    }
  }

  /* /\* iterate over all neighbor IDs */
  /*  *\/ */
  /* private iter Neighbors( nodes, node : index (nodes.domain) ) { */
  /*   for nlElm in nodes(node).neighborList do */
  /*     yield nlElm(1); // todo -- use nid */
  /* } */

  /* /\* iterate over all neighbor IDs */
  /*  *\/ */
  /* iter private Neighbors( nodes, node : index (nodes), param tag: iterKind) */
  /*   where tag == iterKind.leader { */
  /*   for block in nodes(v).neighborList._value.these(tag) do */
  /*     yield block; */
  /* } */

  /* /\* iterate over all neighbor IDs */
  /*  *\/ */
  /* iter private Neighbors( nodes, node : index (nodes), param tag: iterKind, followThis) */
  /*   where tag == iterKind.follower { */
  /*   for nlElm in nodes(v).neighborList._value.these(tag, followThis) do */
  /*     yield nElm(1); */
  /* } */

  /* /\* return the number of neighbors */
  /*  *\/ */
  /* proc n_Neighbors (nodes, node : index (nodes) )  */
  /*   {return Row (v).numNeighbors();} */


  /*   /\* how to use Graph: e.g. */
  /*      const vertex_domain =  */
  /*      if DISTRIBUTION_TYPE == "BLOCK" then */
  /*      {1..N_VERTICES} dmapped Block ( {1..N_VERTICES} ) */
  /*      else */
  /*      {1..N_VERTICES} ; */

  /*      writeln("allocating Associative_Graph"); */
  /*      var G = new Graph (vertex_domain); */
  /*   *\/ */

  /*   /\* Helps to construct a graph from row, column, value */
  /*      format.  */
  /*   *\/ */
  /* proc buildUndirectedGraph(triples, param weighted:bool, vertices) where */
  /*   isRecordType(triples.eltType) */
  /*   { */

  /*     // sync version, one-pass, but leaves 0s in graph */
  /*     /\* */
  /* 	var r: triples.eltType; */
  /* 	var G = new Graph(nodeIdType = r.to.type, */
  /* 	edgeWeightType = r.weight.type, */
  /* 	vertices = vertices); */
  /* 	var firstAvailNeighbor$: [vertices] sync int = G.initialFirstAvail; */
  /* 	forall trip in triples { */
  /*       var u = trip.from; */
  /*       var v = trip.to; */
  /*       var w = trip.weight; */
  /*       // Both the vertex and firstAvail must be passed by reference. */
  /*       // TODO: possibly compute how many neighbors the vertex has, first. */
  /*       // Then allocate that big of a neighbor list right away. */
  /*       // That way there will be no need for a sync, just an atomic. */
  /*       G.Row[u].addEdgeOnVertex(v, w, firstAvailNeighbor$[u]); */
  /*       G.Row[v].addEdgeOnVertex(u, w, firstAvailNeighbor$[v]); */
  /* 	}*\/ */

  /*     // atomic version, tidier */
  /*     var r: triples.eltType; */
  /*     var G = new Graph(nodeIdType = r.to.type, */
  /*                       edgeWeightType = r.weight.type, */
  /*                       vertices = vertices, */
  /*                       initialLastAvail=0); */
  /*     var next$: [vertices] atomic int; */

  /*     forall x in next$ { */
  /*       next$.write(G.initialFirstAvail); */
  /*     } */

  /*     // Pass 1: count. */
  /*     forall trip in triples { */
  /*       var u = trip.from; */
  /*       var v = trip.to; */
  /*       var w = trip.weight; */
  /*       // edge from u to v will be represented in both u and v's edge */
  /*       // lists */
  /*       next$[u].add(1, memory_order_relaxed); */
  /*       next$[v].add(1, memory_order_relaxed); */
  /*     } */
  /*     // resize the edge lists */
  /*     forall v in vertices { */
  /*       var min = G.initialFirstAvail; */
  /*       var max = next$[v].read(memory_order_relaxed) - 1;  */
  /*       G.Row[v].ndom = {min..max}; */
  /*     } */
  /*     // reset all of the counters. */
  /*     forall x in next$ { */
  /*       next$.write(G.initialFirstAvail, memory_order_relaxed); */
  /*     } */
  /*     // Pass 2: populate. */
  /*     forall trip in triples { */
  /*       var u = trip.from; */
  /*       var v = trip.to; */
  /*       var w = trip.weight; */
  /*       // edge from u to v will be represented in both u and v's edge */
  /*       // lists */
  /*       var uslot = next$[u].fetchAdd(1, memory_order_relaxed); */
  /*       var vslot = next$[v].fetchAdd(1, memory_order_relaxed); */
  /*       G.Row[u].neighborList[uslot] = (v,); */
  /*       G.Row[v].neighborList[vslot] = (u,); */
  /*     } */

  /*     return G; */
  /*   } */
}
