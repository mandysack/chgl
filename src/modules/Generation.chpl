module Generation {

  use IO;
  use Random;
  use CyclicDist;
  use AdjListHyperGraph;
  use DestinationBuffers;
  use BlockDist;
  use Math;
  use Sort;
  use Search;

  param GenerationSeedOffset = 0xDEADBEEF;
  config const GenerationUseAggregation = true;

  //Pending: Take seed as input
  //Returns index of the desired item
  inline proc getRandomElement(elements, probabilities,randValue){
    for (idx, probability) in zip(0..#probabilities.size, probabilities) {
      if probability > randValue then return elements.low + idx;
    }
    halt("Bad probability randValue: ", randValue, ", requires one between ",
         probabilities[probabilities.domain.low], " and ", probabilities[probabilities.domain.high]);
  }
  
  proc distributedHistogram(probTable, numRandoms, targetLocales) {
    assert(probTable.domain.stride == 1, "Cannot perform histogram on strided arrays yet");;
    var indicesSpace = {1..#numRandoms};
    var indicesDom = indicesSpace dmapped Block(boundingBox = indicesSpace, targetLocales = targetLocales);
    var indices : [indicesDom] int;
    var rngArr : [indicesDom] real;
    var newProbTableSpace = {1..#probTable.size + 1};
    var newProbTableDom = newProbTableSpace dmapped Cyclic(startIdx=1, targetLocales = targetLocales);
    var newProbTable : [newProbTableSpace] probTable.eltType;
    newProbTable[2..] = probTable;
    fillRandom(rngArr);
    const lo = newProbTable.domain.low;
    const hi = newProbTable.domain.high;
    const size = newProbTable.size;

    // probabilities is binrange, rngArr is X
    forall (rng, ix) in zip(rngArr, indices) {
      // Handle space cases...
      if rng == 0 {
        ix = 0;
      } else if rng == 1 {
        ix = size - 1;
      } else {
        var offset = 1;
        // Find a probability less than or equal to rng in log(n) time
        while (offset <= size && rng > newProbTable[offset]) {
          offset *= 2;
        }

        // Find the first probability less than or equal to rng
        offset = min(offset, size);
        while offset != 0 && rng <= newProbTable[offset - 1] {
          offset -= 1;
        }

        ix = offset - 2;
        assert(ix >= 0);
      }
    }

    return indices;
  }
  
  proc histogram(probabilities, numRandoms) {
    var indices : [1..#numRandoms] int;
    var rngArr : [1..#numRandoms] real;
    var newProbabilities : [1..1] real;
    if numRandoms == 0 then return indices;
    newProbabilities.push_back(probabilities);
    fillRandom(rngArr);
    const lo = newProbabilities.domain.low;
    const hi = newProbabilities.domain.high;
    const size = newProbabilities.size;

    // probabilities is binrange, rngArr is X
    forall (rng, ix) in zip(rngArr, indices) {
      // Handle space cases...
      if rng == 0 {
        ix = 0;
      } else if rng == 1 {
        ix = size - 1;
      } else {
        var offset = 1;
        // Find a probability less than or equal to rng in log(n) time
        while (offset <= size && rng > newProbabilities[offset]) {
          offset *= 2;
        }

        // Find the first probability less than or equal to rng
        offset = min(offset, size);
        while offset != 0 && rng < newProbabilities[offset - 1] {
          offset -= 1;
        }

        ix = offset - 2;
        assert(ix >= 0);
      }
    }
    
    return indices;
  }

  proc generateErdosRenyiSMP(graph, probability, vertexDomain, edgeDomain, couponCollector = true) {
    // Rounds a real into an int
    proc _round(x : real) : int {
      return round(x) : int;
    }
    const numVertices = vertexDomain.size;
    const numEdges = edgeDomain.size;
    var newP = if couponCollector then log(1/(1-probability)) else probability;
    var inclusionsToAdd = _round(numVertices * numEdges * newP);
    // Perform work evenly across all tasks
    var _randStream = new RandomStream(int, GenerationSeedOffset + here.id * here.maxTaskPar);
    var randStream = new RandomStream(int, _randStream.getNext());
    forall 1..inclusionsToAdd {
      var vertex = randStream.getNext(vertexDomain.low, vertexDomain.high);
      var edge = randStream.getNext(edgeDomain.low, edgeDomain.high);
      graph.addInclusion(vertex, edge);
    }

    return graph;
  }
  
  proc generateErdosRenyi(graph, probability, verticesDomain = graph.verticesDomain, edgesDomain = graph.edgesDomain, couponCollector = true, targetLocales = Locales){
    const numVertices = verticesDomain.size;
    const numEdges = edgesDomain.size;
    const vertLow = verticesDomain.low;
    const edgeLow = edgesDomain.low;
    var newP = if couponCollector then log(1/(1-probability)) else probability;
    var inclusionsToAdd = round(numVertices * numEdges * newP) : int;
    var space = {1..inclusionsToAdd};
    var dom = space dmapped Block(boundingBox=space, targetLocales=targetLocales);
    var verticesRNG : [dom] real;
    var edgesRNG : [dom] real;
    fillRandom(verticesRNG);
    fillRandom(edgesRNG);

    sync forall (v, e) in zip(verticesRNG, edgesRNG) with (in graph) {
      var vertex = round(v * (numVertices - 1)) : int;
      var edge = round(e * (numEdges - 1)) : int;
      graph.addInclusionBuffered(vertLow + vertex, edgeLow + edge);
    }
    graph.flushBuffers();
    
    return graph;
  }

  //Pending: Take seed as input
  proc generateErdosRenyiNaive(graph, vertices_domain, edges_domain, p, targetLocales = Locales) {
    // Spawn a remote task on each node...
    coforall loc in targetLocales with (in graph) do on loc {
      var _randStream = new RandomStream(int, GenerationSeedOffset + here.id * here.maxTaskPar);
      var randStream = new RandomStream(int, _randStream.getNext());

      // Process either vertices of edges in parallel based on relative size.
      if graph.numVertices > graph.numEdges {
        forall v in graph.localVerticesDomain {
          for e in graph.localEdgesDomain {
            if randStream.getNext() <= p {
              graph.addInclusion(v,e);
            }
          }
        }
      } else {
        forall e in graph.localEdgesDomain {
          for v in graph.localVerticesDomain {
            if randStream.getNext() <= p {
              graph.addInclusion(v,e);
            }
          }
        }
      }
    }
    
    return graph;
  }
  
  proc generateChungLuSMP(graph, verticesDomain, edgesDomain, desiredVertexDegrees, desiredEdgeDegrees, inclusionsToAdd) {
    const reducedVertex = + reduce desiredVertexDegrees : real;
    const reducedEdge = + reduce desiredEdgeDegrees : real;
    var vertexProbabilities = desiredVertexDegrees / reducedVertex;
    var edgeProbabilities = desiredEdgeDegrees/ reducedEdge;
    var vertexScan : [vertexProbabilities.domain] real = + scan vertexProbabilities;
    var edgeScan : [edgeProbabilities.domain] real = + scan edgeProbabilities;


    return generateChungLuPreScanSMP(graph, verticesDomain, edgesDomain, vertexScan, edgeScan, inclusionsToAdd);
  }

  proc generateChungLuPreScanSMP(graph, verticesDomain, edgesDomain, vertexScan, edgeScan, inclusionsToAdd){
    // Perform work evenly across all locales
    coforall tid in 0..#here.maxTaskPar {
      // Perform work evenly across all tasks
      var perTaskInclusions = inclusionsToAdd / here.maxTaskPar + (if tid == 0 then inclusionsToAdd % here.maxTaskPar else 0);
      var _randStream = new RandomStream(int, GenerationSeedOffset + here.id * here.maxTaskPar + tid);
      var randStream = new RandomStream(real, _randStream.getNext());
      for 1..perTaskInclusions {
        var vertex = getRandomElement(verticesDomain, vertexScan, randStream.getNext());
        var edge = getRandomElement(edgesDomain, edgeScan, randStream.getNext());
        graph.addInclusion(vertex, edge);
      }
    }

    return graph;
  }
  
  /*
    Generates a graph from the desired vertex and edge degree sequence.

    :arg graph: Mutable graph to generate.
    :arg vDegSeq: Vertex degree sequence.
    :arg eDegSeq: HyperEdge degree sequence.
    :arg inclusionsToAdd: Number of edges to create between vertices and hyperedges.
    :arg verticesDomain: Subset of vertices to generate edges between. Defaults to the entire set of vertices.
    :arg edgesDomain: Subset of hyperedges to generate edges between. Defaults to the entire set of hyperedges.
  */
  proc generateChungLu(
      graph, vDegSeq : [?vDegSeqDom] int, eDegSeq : [?eDegSeqDom] int, inclusionsToAdd : int(64),
      verticesDomain = graph.verticesDomain, edgesDomain = graph.edgesDomain) {
    // Check if empty...
    if inclusionsToAdd == 0 || graph.verticesDomain.size == 0 || graph.edgesDomain.size == 0 then return graph;
  
    // Obtain prefix sum of the normalized degree sequences
    // This is used as a table to sample vertex and hyperedges from random number
    var vertexProbabilityTable = + scan (vDegSeq / (+ reduce vDegSeq):real);
    var edgeProbabilityTable = + scan (eDegSeq / (+ reduce eDegSeq):real);

    writeln(max reduce vertexProbabilityTable);
    writeln(max reduce edgeProbabilityTable);

    // Perform work evenly across all locales
    coforall loc in Locales with (in graph) do on loc {
      const vpt = vertexProbabilityTable;
      const ept = edgeProbabilityTable;
      const perLocInclusions = inclusionsToAdd / numLocales + (if here.id == 0 then inclusionsToAdd % numLocales else 0);
      sync coforall tid in 0..#here.maxTaskPar with (in graph) {
        // Perform work evenly across all tasks
        var perTaskInclusions = perLocInclusions / here.maxTaskPar + (if tid == 0 then perLocInclusions % here.maxTaskPar else 0);
        var _randStream = new RandomStream(int, GenerationSeedOffset + here.id * here.maxTaskPar + tid);
        var randStream = new RandomStream(real, _randStream.getNext());
        for 1..perTaskInclusions {
          var vertex = getRandomElement(verticesDomain, vpt, randStream.getNext());
          var edge = getRandomElement(edgesDomain, ept, randStream.getNext());
          graph.addInclusionBuffered(vertex, edge);
        }
      }
      graph.flushBuffers();
    }
    return graph;
  }
  
  proc generateChungLuAdjusted(graph, num_vertices, num_edges, desired_vertex_degrees, desired_edge_degrees){
    var inclusions_to_add =  + reduce desired_vertex_degrees:int;
    return generateChungLu(graph, num_vertices, num_edges, desired_vertex_degrees, desired_edge_degrees, inclusions_to_add);
  }

  // Computes the triple (nV, nE, rho) which are used to determine affinity blocks
  proc computeAffinityBlocks(dV, dE, mV, mE){
      var (nV, nE, rho) : 3 * real;

      //determine the nV, nE, rho
      if (mV / mE >= 1) {
        nV = dE;
        nE = (mV / mE) * dV;
        rho = (((dV - 1) * (mE ** 2.0)) / (mV * dV - mE)) ** (1 / 4.0);
      } else {
        nE = dV;
        nV = (mE / mV) * dE;
        rho = (((dE - 1) * (mV ** 2.0))/(mE * dE - mV)) ** (1 / 4.0);
      }

      assert(!isnan(rho), (dV, dE, mV, mE), "->", (nV, nE, rho));

      return (_round(nV), _round(nE), rho);
  }

  // Rounds a real into an int
  proc _round(x : real) : int {
      return round(x) : int;
  }

  /*
    Block Two-Level Erdos Renyi
  */
  proc generateBTER(
      vd : [?vdDom], /* Vertex Degrees */
      ed : [?edDom], /* Edge Degrees */
      vmc : [?vmcDom], /* Vertex Metamorphosis Coefficient */
      emc : [?emcDom], /* Edge Metamorphosis Coefficient */
      targetLocales = Locales
      ) {

    // Obtains the minimum value that exceeds one
    proc minimalGreaterThanOne(arr) {
      for (a, idx) in zip(arr, arr.dom) do if a > 1 then return idx;
      halt("No member found that is greater than 1...");
    }

    // Check if data begins at index 0...
    assert(vdDom.low == 0 && edDom.low == 0 && vmcDom.low == 0 && emcDom.low == 0);

    cobegin {
      sort(vd);
      sort(ed);
    }

    var (nV, nE, rho) : 3 * real;
    var (idV, idE, numV, numE) = (
        minimalGreaterThanOne(vd),
        minimalGreaterThanOne(ed),
        vdDom.size,
        edDom.size
        );
    var graph = new AdjListHyperGraph(vdDom.size, edDom.size, new Cyclic(startIdx=0));

    var blockID = 1;
    var expectedDuplicates : int;
    while (idV <= numV && idE <= numE){
      var (dV, dE) = (vd[idV], ed[idE]);
      var (mV, mE) = (vmc[dV - 1], emc[dE - 1]);
      (nV, nE, rho) = computeAffinityBlocks(dV, dE, mV, mE);
      var nV_int = nV:int;
      var nE_int = nE:int;
      blockID += 1;

      // Check to ensure that blocks are only applied when it fits
      // within the range of the number of vertices and edges provided.
      // This avoids processing a most likely "wrong" value of rho as
      // mentioned by Sinan.
      if (((idV + nV_int) <= numV) && ((idE + nE_int) <= numE)) {
        const ref fullVerticesDomain = graph.verticesDomain;
        const verticesDomain = fullVerticesDomain[idV..#nV_int];
        const ref fullEdgesDomain = graph.edgesDomain;
        const edgesDomain = fullEdgesDomain[idE..#nE_int];
        expectedDuplicates += round((nV_int * nE_int * log(1/(1-rho))) - (nV_int * nE_int * rho)) : int;
        generateErdosRenyi(graph, rho, verticesDomain, edgesDomain, couponCollector = true);
        idV += nV_int;
        idE += nE_int;
      } else {
        break;
      }
    }
    writeln("Duplicates: ", graph.removeDuplicates(), " and expect: ", expectedDuplicates); 
    forall (v, vDeg) in graph.forEachVertexDegree() {
      var oldDeg = vd[v.id];
      vd[v.id] = max(0, oldDeg - vDeg);
    }
    forall (e, eDeg) in graph.forEachEdgeDegree() {
      var oldDeg = ed[e.id];
      ed[e.id] = max(0, oldDeg - eDeg);
    }
    var nInclusions = _round(max(+ reduce vd, + reduce ed));
    generateChungLu(graph, vd, ed, nInclusions);
    return graph;
  }
}

