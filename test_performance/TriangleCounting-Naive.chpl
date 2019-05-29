use WorkQueue;
use BlockDist;
use Vectors;
use Utilities;
use Time;

config const dataset = "../data/karate.mtx_csr.bin";
beginProfile("TriangleCounting-Naive-Profile");
try! {
  var f = open(dataset, iomode.r, style = new iostyle(binary=1));   
  var reader = f.reader();
  var timer = new Timer();
  timer.start();

  // Read in |V| and |E|
  var numVertices : uint(64);
  var numEdges : uint(64);
  reader.read(numVertices);
  reader.read(numEdges);
  debug("|V| = " + numVertices);
  debug("|E| = " + numEdges);
  reader.close();
  f.close();
  
  var D = {0..#numVertices} dmapped Block(boundingBox={0..#numVertices});
  var A : [D] owned Vector(int);
  
  // On each node, independently process the file and offsets...
  coforall loc in Locales do on loc {
    var f = open(dataset, iomode.r, style = new iostyle(binary=1));
    debug("Node #", here.id, " beginning to process localSubdomain ", D.localSubdomain());
    // Obtain offset for indices that are local to each node...
    forall idx in D.localSubdomain() {
      // Open file again and skip to portion of file we want...
      var reader = f.reader();
      reader.advance(16 + idx * 8);
      debug("Starting at file offset ", reader.offset(), " for offset table of idx #", idx);

      // Read our beginning and ending offset... since the ending is the next
      // offset minus one, we can just read it from the file and avoid
      // unnecessary communication with other nodes.
      var beginOffset : uint(64);
      var endOffset : uint(64);
      reader.read(beginOffset);
      reader.read(endOffset);
      endOffset -= 1;
      debug("Offsets into adjacency list for idx #", idx, " are ", beginOffset..endOffset);

      // Advance to current idx's offset...
      var skip = ((numVertices - idx:uint - 1:uint) + beginOffset) * 8;
      reader.advance(skip:int);
      debug("Adjacency list offset begins at file offset ", reader.offset());


      // TODO: Request storage space in advance for graph...
      // Read in adjacency list for edges... Since 'addInclusion' already push_back
      // for the matching vertices and edges, we only need to do this once.
      A[idx] = new owned VectorImpl(int, {0..#(endOffset - beginOffset + 1)});
      for beginOffset : int..endOffset : int {
        var edge : uint(64);
        reader.read(edge);
        A[idx].append(edge : int);
        debug("Added inclusion for vertex #", idx, " and edge #", edge);
      }
      A[idx].sort();
      reader.close();
    }
  }
  timer.stop();
  writeln("Initialized Graph in ", timer.elapsed(), "s");
  timer.clear();
  timer.start();
  var numTriangles : int;
  forall v in A.domain with (+ reduce numTriangles) {
    for u in A[v] do if v > u {
      numTriangles += A[v].intersectionSize(A[u]);
    }
  }
  timer.stop();
  writeln("|V| = ", numVertices, ", |E| = ", numEdges, ", numTriangles = ", numTriangles / 3, ", in ", timer.elapsed(), "s");
  f.close();
}
endProfile();
