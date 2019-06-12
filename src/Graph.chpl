
/*
 Prototype 2-Uniform Hypergraph. Forwards implementation to AdjListHyperGraph and should
 support simple 'addEdge(v1,v2)' and 'forall (v1, v2) in graph.getEdges()'; everything else
 should be forwarded to the underlying Hypergraph.
*/
module Graph {
  use AdjListHyperGraph;
  use Utilities;
  use AggregationBuffer;
  use Vectors;

  pragma "always RVF"
  record Graph {
    var instance;
    var pid : int = -1;
    
    proc init(numVertices : integral, numEdges : integral) {
      init(numVertices, numEdges, new unmanaged DefaultDist(), new unmanaged DefaultDist());
    }
    
    proc init(numVertices : integral, numEdges : integral, mapping) {
      init(numVertices, numEdges, mapping, mapping);  
    }
      
    proc init(
      // Number of vertices
      numVertices : integral,
      // Number of edges
      numEdges : integral,
      // Distribution of vertices
      verticesMappings, 
      // Distribution of edges
      edgesMappings
    ) {
      instance = new unmanaged GraphImpl(
        numVertices, numEdges, verticesMappings, edgesMappings
      );
      pid = instance.pid;
    }

    proc _value {
      if pid == -1 {
        halt("Attempt to use Graph when uninitialized...");
      }

      return chpl_getPrivatizedCopy(instance.type, pid);
    }
    
    proc destroy() {
      if pid == -1 then halt("Attempt to destroy 'Graph' which is not initialized...");
      coforall loc in Locales do on loc {
        delete chpl_getPrivatizedCopy(instance.type, pid);
      }
      pid = -1;
      instance = nil;
    }

    forwarding _value;
  }

  class GraphImpl {
    // privatization id of this
    var pid : int;
    // Hypergraph implementation. The implementation will be privatized before us
    // and so we can 'hijack' its privatization id for when we privatized ourselves.
    var hg;
    // Keep track of edges currently used... Scalable if we have RDMA atomic support,
    // either way it should allow high amounts of concurrency. Note that for now we
    // do not support removing edges from the graph. 
    // TODO: Can allow this by keeping track of a separate counter of inuseEdges and then
    // if inusedEdges < maxNumEdges, use edgeCounter to round-robin for an available edge.
    var edgeCounter;
    type vDescType;
    // Aggregates '(u, v, eIdx)' where the edge corresponding to eIdx is used for (u,v).
    // Other locales will aggregate (u,v,-1) to locale 0, upon which on locale 0, an
    // edge will be grabbed via atomic fetchAdd for the whole buffer, and then the new
    // index, eIdx, will be aggregated as (u,v,eIdx) to locale that vertex u is located on.
    var insertAggregator = UninitializedAggregator((hg.vDescType, hg.vDescType, int));
    // Cached mappings of vertex-to-vertex neighbor lists. This elides the performance overhead
    // associated with using the underlying hypergraph's adjacency lists. This will get updated
    // via a call from the user. If an insertion occurs, this mapping will become invalid across
    // all locales. Calls to 'invalidateCache' can be made to invalidate it manually, and calls
    // to 'validateCache' can be used prior to operations that will greatly benefit from the cache.
    // When the cache is not valid, all queries will use the underlying hypergraph.
    var cachedNeighborListDom : hg.verticesDomain.type;
    var cachedNeighborList : [cachedNeighborListDom] unmanaged Vector(hg.vDescType);
    var privatizedCachedNeighborListInstance = cachedNeighborList._value;
    var privatizedCachedNeighborListPID = cachedNeighborList._pid;
    var cacheValid : atomic bool;

    proc init(numVertices, numEdges, verticesMapping, edgesMapping) {
      hg = new unmanaged AdjListHyperGraphImpl(numVertices, numEdges, verticesMapping, edgesMapping);
      edgeCounter = new unmanaged Centralized(atomic int);
      this.vDescType = hg.vDescType;
      if CHPL_NETWORK_ATOMICS == "none" {
        insertAggregator = new Aggregator((hg.vDescType, hg.vDescType, int));
      }
      this.cachedNeighborListDom = hg.verticesDomain;
      complete();
      forall vec in cachedNeighborList do vec = new unmanaged VectorImpl(hg.vDescType, {0..-1});
      this.pid = _newPrivatizedClass(this:unmanaged); 
    }

    proc init(other : GraphImpl, pid : int) {
      this.pid = pid;
      // Grab privatized instance from original hypergraph.
      this.hg = chpl_getPrivatizedCopy(other.hg.type, other.hg.pid); 
      this.edgeCounter = other.edgeCounter;
      this.vDescType = other.vDescType;
      this.insertAggregator = other.insertAggregator;
      if other.locale == Locales[0] {
        this.privatizedCachedNeighborListInstance = other.cachedNeighborList._value;
        this.privatizedCachedNeighborListPID = other.cachedNeighborList._pid;
      } else {
        this.privatizedCachedNeighborListInstance = 
          chpl_getPrivatizedCopy(other.privatizedCachedNeighborListInstance.type, other.privatizedCachedNeighborListPID);
        this.privatizedCachedNeighborListPID = other.privatizedCachedNeighborListPID;
      }
    }

    pragma "no doc"
    proc dsiPrivatize(pid) {
      return new unmanaged GraphImpl(this, pid);
    }

    pragma "no doc"
    proc dsiGetPrivatizeData() {
      return pid;
    }

    pragma "no doc"
    inline proc getPrivatizedInstance() {
      return chpl_getPrivatizedCopy(this.type, pid);
    }

    pragma "no doc"
    inline proc aggregateEdge(v1 : hg.vDescType, v2 : hg.vDescType) {
      var buf = insertAggregator.aggregate((v1, v2, -1), Locales[0]);
      if buf != nil {
        begin with (in buf) {
          var arr = buf.getArray();
          buf.done();
          var startIdx = edgeCounter.fetchAdd(arr.size);
          var endIdx = startIdx + arr.size - 1;
          if endIdx >= hg.edgesDomain.size {
            halt("Out of Edges! Ability to grow coming soon!");
          }
          for ((v1, v2, _), eIdx) in zip(arr, startIdx..#arr.size) {
            hg.addInclusionBuffered(v1, hg.toEdge(eIdx));
            hg.addInclusionBuffered(v2, hg.toEdge(eIdx));
          }
        }
      }
    }
    
    proc invalidateCache() {
      if !isCacheValid() then return;
      coforall loc in Locales do on loc {
        getPrivatizedInstance().cacheValid.write(false);
      }

      // TODO: Delete all vectors or clear them?
    }

    proc validateCache() {
      if isCacheValid() then return;
      on Locales[0] {
        var _this = getPrivatizedInstance();
        forall (v, vec) in zip(_this.hg.getVertices(), _this.cachedNeighborList) {
          vec.clear();
          var __this = getPrivatizedInstance();
          for neighbor in __this.neighbors(v) do vec.append(neighbor);
          vec.sort();
        }
      }
      coforall loc in Locales do on loc {
        getPrivatizedInstance().cacheValid.write(true);
      }
    }

    proc isCacheValid() {
      return cacheValid.read();
    }

    proc addEdge(v1 : integral, v2 : integral) {
      addEdge(hg.toVertex(v1), hg.toVertex(v2));
    }

    proc addEdge(v1 : hg.vDescType, v2 : hg.vDescType) {
      if isCacheValid() then invalidateCache();
      if here != Locales[0] && CHPL_NETWORK_ATOMICS == "none" {
        aggregateEdge(v1, v2);
        return;
      }
      var eIdx = edgeCounter.fetchAdd(1);
      if eIdx >= hg.edgesDomain.size {
        halt("Out of Edges! Ability to grow coming soon!");
      }
      var e = hg.toEdge(eIdx);
      hg.addInclusion(v1, e);
      hg.addInclusion(v2, e);
    }

    // Should be called after filling the graph
    proc flush() {
      if CHPL_NETWORK_ATOMICS == "none" {
        forall (buf, loc) in insertAggregator.flushGlobal() {
          assert(loc == Locales[0]);
          on Locales[0] {
            var arr = buf.getArray();
            buf.done();
            var _this = getPrivatizedInstance();
            var startIdx = _this.edgeCounter.fetchAdd(arr.size);
            var endIdx = startIdx + arr.size - 1;
            if endIdx >= _this.hg.edgesDomain.size {
              halt("Out of Edges! Ability to grow coming soon!");
            }
            for ((v1, v2, _), eIdx) in zip(arr, startIdx..#arr.size) {
              _this.hg.addInclusionBuffered(v1, _this.hg.toEdge(eIdx));
              _this.hg.addInclusionBuffered(v2, _this.hg.toEdge(eIdx));
            }
          }
        }

      }
      hg.flushBuffers();
    }

    iter getEdges() : (hg.vDescType, hg.vDescType) {
      if isCacheValid() {
        for (v, vec) in zip(hg.getVertices(), privatizedCachedNeighborListInstance) {
          for u in vec do yield (hg.toVertex(v),u);
        }
      } else {
        for e in hg.getEdges() {
          var sz = hg.getEdge(e).size.read();
          if sz > 2 {
            halt("Edge ", e, " has more than two vertices: ", hg.getEdge(e).incident);
          }
          if sz == 0 {
            continue;
          }

          yield (hg.toVertex(hg.getEdge(e).incident[0]), hg.toVertex(hg.getEdge(e).incident[1]));
        }
      }
    }
   

    iter getEdges(param tag : iterKind) : (hg.vDescType, hg.vDescType) where tag == iterKind.standalone {
      if isCacheValid() {
        forall (v, vec) in zip(hg.getVertices(), privatizedCachedNeighborListInstance) {
          for u in vec do yield (hg.toVertex(v),u);
        }
      } else {
        forall e in hg.getEdges() {
          var sz = hg.getEdge(e).size.read();
          if sz > 2 {
            halt("Edge ", e, " is has more than two vertices: ", hg.getEdge(e).incident);
          }
          if sz == 0 {
            continue;
          }

          yield (hg.toVertex(hg.getEdge(e).incident[0]), hg.toVertex(hg.getEdge(e).incident[1]));
        }
      }    
    }

    // Return neighbors of a vertex 'v'
    iter neighbors(v : integral) {
      for vv in neighbors(hg.toVertex(v)) do yield vv;
    }

    iter neighbors(v : integral, param tag : iterKind) where tag == iterKind.standalone {
      forall vv in neighbors(hg.toVertex(v)) do yield vv;
    }

    iter neighbors(v : hg.vDescType) {
      if isCacheValid() {
        for vv in privatizedCachedNeighborListInstance.dsiAccess(v.id) do yield vv;
      } else {
        for vv in hg.walk(v) do yield vv;
      }
    }

    iter neighbors(v : hg.vDescType, param tag : iterKind) where tag == iterKind.standalone {
      if isCacheValid() {
        forall vv in privatizedCachedNeighborListInstance.dsiAccess(v.id) do yield vv;
      } else {
        forall vv in hg.walk(v) do yield vv;
      }
    }

    proc hasEdge(v1 : integral, v2 : integral) {
      return hasEdge(hg.toVertex(v1), hg.toVertex(v2)); 
    }
    
    proc hasEdge(v1 : integral, v2 : hg.vDescType) {
      return hasEdge(hg.toVertex(v1), v2);
    }

    proc hasEdge(v1 : hg.vDescType, v2 : integral) {
      return hasEdge(v1, hg.toVertex(v2));
    }

    proc hasEdge(v1 : hg.vDescType, v2 : hg.vDescType) {
      if isCacheValid() {
        return any([v in privatizedCachedNeighborListInstance.dsiAccess(v1.id)] v.id == v2.id);
      } else {
        return any([v in hg.walk(v1)] v.id == v2.id); 
      }
    }

    proc intersection(_v1, _v2) {
      var v1 = hg.toVertex(_v1);
      var v2 = hg.toVertex(_v2);
      if isCacheValid() {
        return Utilities.intersection(
            privatizedCachedNeighborListInstance.dsiAccess(v1.id).getArray(), privatizedCachedNeighborListInstance.dsiAccess(v2.id).getArray()
        );
      } else {
        hg.getVertex(v1).sortIncidence(true);
        hg.getVertex(v2).sortIncidence(true);
        var A = neighbors(v1);
        var B = neighbors(v2);
        return Utilities.intersection(A, B);
      }
    }

    proc intersectionSize(_v1, _v2) {
      var v1 = hg.toVertex(_v1);
      var v2 = hg.toVertex(_v2);
      if isCacheValid() {
        return Utilities.intersectionSize(
            privatizedCachedNeighborListInstance.dsiAccess(v1.id).getArray(), privatizedCachedNeighborListInstance.dsiAccess(v2.id).getArray()
        );
      } else {
      hg.getVertex(v1).sortIncidence(true);
      hg.getVertex(v2).sortIncidence(true);
      var A = neighbors(v1);
      var B = neighbors(v2);
      return Utilities.intersectionSize(A, B);
      }
    }

    proc simplify() {
      on Locales[0] do getPrivatizedInstance().hg.collapse();
    }

    proc degree(v : hg.vDescType) {
       if isCacheValid() {
        return privatizedCachedNeighborListInstance.dsiAccess(v.id).size();
      } else {
        return + reduce [_unused_ in hg.walk(v)] 1;
      }
    }

    proc degree(v : integral) : int {
      return degree(hg.toVertex(v));
    }

    forwarding hg only toVertex, getVertices, numVertices, 
               getLocale, verticesDomain, startAggregation, 
               stopAggregation, numEdges;
  }
}
