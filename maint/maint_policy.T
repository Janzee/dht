// -*-c++-*-
// vim: filetype=cpp  foldmethod=marker
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpc.h>

#include <chord_prot.h>
#include <comm.h>
#include <merkle.h>
#include <merkle_tree_disk.h>

#include <id_utils.h>
#include <location.h>
#include <libadb.h>
#include <rpclib.h>

#include <maint_prot.h>
#include "maint_policy.h"

// {{{ locationcc - TCP connection management
vec<locationcc *> locationcc::allocated;

locationcc::locationcc (const chord_node &n) :
    n (n),
    x (NULL),
    reapcaller (NULL)
{
  allocated.push_back (this);
}

ptr<locationcc>
locationcc::alloc (const chord_node &n)
{
  for (size_t i = 0; i < allocated.size (); i++) {
    if (allocated[i]->n.x == n.x)
      return mkref (allocated[i]);
  }
  return New refcounted<locationcc> (n);
}


TAMED void
locationcc::get_stream_aclnt (const rpc_program &p,
    callback<void, ptr<aclnt> >::ref cb)
{
  VARS {
    int fd (-1);
    ptr<aclnt> c (NULL);
  }

  if (x) {
    assert (reapcaller);
    timecb_remove (reapcaller);
    reapcaller = NULL;
    c = aclnt::alloc (x, p);
  } else {
    assert (!reapcaller);
    BLOCK {
      tcpconnect (n.r.hostname,
		  n.r.port-1, // LAME CONVENTION
		  @(fd));
    }
    if (fd < 0) {
      warn << "locationcc: connect to " << n << " failed:" <<
	strerror (errno) << "\n";
      cb (c);
      return;
    }
    x = axprt_stream::alloc (fd);
    c = aclnt::alloc (x, p);
  }
  // XXX: delay should be long enough so that a round can finish
  // and we can be here to use the cached connection next time.
  reapcaller = delaycb (1200, wrap (this, &locationcc::reaper));
  cb (c);
}

void
locationcc::fill_ipportvn (u_int32_t &a, u_int32_t &b)
{
  sockaddr_in saddr;
  bzero (&saddr, sizeof(sockaddr_in));
  // saddr.sin_family = AF_INET;
  inet_aton (n.r.hostname.cstr (), &saddr.sin_addr);
  saddr.sin_port = htons (n.r.port);
  /* saddr fields are in network byte order */
  a = ntohl (saddr.sin_addr.s_addr);
  b = (ntohs (saddr.sin_port) << 16) | n.vnode_num;
}

void
locationcc::reaper () {
  reapcaller = NULL;
  // Forget about the axprt.  This will cause the connection
  // to close as soon as any outstanding aclnt's lose their last ref.
  x = NULL;
}

locationcc::~locationcc () {
  if (reapcaller) {
    timecb_remove (reapcaller);
    reapcaller = NULL;
  }
  for (size_t i = 0; i < allocated.size (); i++) {
    if (allocated[i] == this) {
      allocated[i] = allocated.pop_back ();
      break;
    }
  }
}
// }}}

// {{{ maintainer - base maintainer class
static str ctype2ext (dhash_ctype c) {
  switch (c) {
  case DHASH_CONTENTHASH:
    return "c";
    break;
  case DHASH_KEYHASH:
    return "k";
    break;
  case DHASH_NOAUTH:
    return "n";
    break;
  default:
    fatal << "bad ctype\n";
  }
}

const u_int32_t maintainer::default_delay = 300;
maintainer::maintainer (str path, maint_dhashinfo_t *hostinfo, ptr<syncer> s) :
  host (hostinfo->host),
  ctype (hostinfo->ctype),
  sync (s),
  efrags (hostinfo->dfrags),
  dfrags (hostinfo->efrags),
  db (New refcounted<adb> (hostinfo->dbsock, hostinfo->dbname, hostinfo->hasaux)),
  private_path (path),
  running (false),
  in_progress (false),
  delay (default_delay),
  mainttimer (NULL)
{
}

maintainer::~maintainer () 
{
  stop ();
}

void
maintainer::start (u_int32_t d)
{
  delay = d;
  if (mainttimer || in_progress)
    return;
  running = true;
  mainttimer = delaycb (delay,
      wrap (this, &maintainer::start_helper));
}
void maintainer::start_helper ()
{
  mainttimer = NULL;
  // Helper is needed for delaycb since run_cycle is TAMED.
  run_cycle (wrap (this, &maintainer::restart, delay));
}

void
maintainer::restart (u_int32_t d)
{
  if (running)
    start (d);
}

void
maintainer::stop ()
{
  if (mainttimer) {
    timecb_remove (mainttimer);
    mainttimer = NULL;
  }
  // If we are in-progress, make sure we don't restart later.
  // We do not have control to stop an in-process sync.
  running = false;
}

TAMED void
maintainer::run_cycle (cbv cb)
{
  in_progress = true;
  BLOCK {
    update_neighbors (@());
  }
  if (preds.size () >= 2) {
    BLOCK { 
      process_neighbors (preds, succs, @());
    }
  }
  in_progress = false;
  delaycb (0, cb);
}

TAMED void
maintainer::update_neighbors (cbv cb)
{
  VARS {
    ptr<chordID> id;
    chord_nodelistres *slist;
    chord_nodelistres *plist;
    clnt_stat e1, e2;
  }
  id = New refcounted<chordID> (host.x);

  slist = New chord_nodelistres ();
  plist = New chord_nodelistres ();
  BLOCK {
    doRPC (host, chord_program_1, CHORDPROC_GETPREDLIST, 
	   id, plist, @(e1));
    doRPC (host, chord_program_1, CHORDPROC_GETSUCCLIST,
	   id, slist, @(e2));
  }
  if (e1 || e2) {
    warn << "my local node is down.\n";
    goto updateOUT;
  }

  // Predecessor and predecessor list (for range).
  {
    size_t sz = plist->resok->nlist.size ();
    preds.clear ();
    for (size_t i = 1; i < sz; i++) {
      chord_node n = make_chord_node (plist->resok->nlist[i]);
      ptr<locationcc> s = locationcc::alloc (n);
      preds.push_back (s);
    }
  }

  // Successor
  {
    size_t sz = slist->resok->nlist.size ();
    succs.clear ();
    for (size_t i = 1; i < sz; i++) {
      chord_node n = make_chord_node (slist->resok->nlist[i]);
      ptr<locationcc> s = locationcc::alloc (n);
      succs.push_back (s);
    }
  }

updateOUT:
  if (slist)
    delete slist;
  if (plist)
    delete plist;
  cb ();
}

TAMED void
maintainer::process_neighbors (
    const vec<ptr<locationcc> > &preds,
    const vec<ptr<locationcc> > &succs, cbv cb)
{
  // See Carbonite, Passing Tone or other implementations.
  cb ();
}
// }}}
// {{{ Carbonite
ref<maintainer> 
carbonite::produce_maintainer (str path, maint_dhashinfo_t *hostinfo, ptr<syncer> s)
{
  return New refcounted<carbonite> (path, hostinfo, s);
}

carbonite::carbonite (str path, maint_dhashinfo_t *hostinfo, ptr<syncer> s) :
    maintainer (path, hostinfo, s),
    ltree (NULL)
{
  db->getspaceinfo (wrap (this, &carbonite::init_ltree));
}

void 
carbonite::init_ltree (adb_status err, str path, bool hasaux)
{
  if (err) {
    warn << "carbonite::init_ltree: Unexpected adbd error: " << err << "\n";
    return;
  }
  ltree = New refcounted<merkle_tree_disk> (path, /* rw = */ false);
}

carbonite::~carbonite ()
{
}

void 
carbonite::handle_missing (ptr<locationcc> from,
    ptr<merkle_tree> t,
    bigint key, bool missing_local)
{
  // Make the local tree look identical to the remote tree.
  // For now, also keep the adbd register up to date.
  ptr<location> rfrom = New refcounted<location> (from->chordnode ());
  if (db->hasaux ()) {
    chordID aux = (key & 0xFFFFFFFF);
    chordID dbkey = (key >> 32) << 32;
    db->update (dbkey, rfrom, aux.getui (), missing_local, true);
    if (missing_local) {
      t->insert (dbkey, aux.getui ());
    } else {
      t->remove (dbkey, aux.getui ());
    }
  } else {
    db->update (key, rfrom, missing_local, true);
    if (missing_local) {
      t->insert (key);
    } else {
      t->remove (key);
    }
  }
}

TAMED void
carbonite::process_neighbors (
    const vec<ptr<locationcc> > &preds,
    const vec<ptr<locationcc> > &succs,
    cbv cb)
{
  VARS {
    chordID rngmin, rngmax;
  }

  // Our range starts before our efrag-th predecessor.
  // Unless there are so few nodes that all objects are fully replicated.
  if (preds.size() > efrags) 
    rngmin = preds[efrags]->id ();
  else
    rngmin = incID (host.x);
  rngmax = host.x;

  BLOCK {
    // Merkle data structures for remote nodes are private to maintd.
    for (unsigned int i=0; i < succs.size(); i++) {
      strbuf succtreepath; succtreepath << private_path << "/" 
	<< host.vnode_num << "-"
	<< succs[i]->id () << "." << ctype2ext (ctype);
      ptr<merkle_tree> t = New refcounted<merkle_tree_disk> 
	(succtreepath, /* rw = */ true);
      sync->sync_with (succs[i], rngmin, rngmax,
	  t, 
	  wrap (this, &carbonite::handle_missing, succs[i], t),
	  @());
    }
  }
  cb ();
}

struct keycounter {
  chordID id;
  unsigned int presence;
  unsigned int count;
  itree_entry<keycounter> ik;
  keycounter (chordID id) : id (id), presence (0), count (0) {}
  void add (unsigned int i) {
    assert (i < sizeof (presence));
    unsigned int x = 1 << i;
    if (presence & x == x) return;
    presence |= x;
    count++;
  }
  int firstvoid () {
    unsigned int t = presence;
    unsigned int i = 0;
    while (t) {
      if (!(t & 1))
	return i;
      i++; t >>= 1;
    }
    return sizeof (unsigned int);
  }
};
// Find the first leaf page that includes 'start'.
// For each tree, read in the next leaf page and place the keys
// in that page into a tree that counts replicas.
// Maintain a last key read for each tree (lastread).
// Find the min key in highcount.
// Iterate over the rbcounttree up until min(lastread) to find
// possible things to repair.
// If we have found at least 'count' objects, return!
// Otherwise, loop.
void
carbonite::getrepairs (chordID start, int thresh, int count,
      rpc_vec<maint_repair_t, RPC_INFINITY> &repairs)
{
  if (in_progress) {
    warn << host << ": Not returning repairs while sync is active.\n";
    return;
  }

  vec<ptr<merkle_tree> > trees;
  vec<chordID> lastread;
  vec<bool> treedone;
  chordID stop = host.x;
  itree<chordID, keycounter, &keycounter::id, &keycounter::ik> keymap;

  for (unsigned int i = 0; i < succs.size (); i++) {
    strbuf succtreepath; succtreepath << private_path << "/" 
      << host.vnode_num << "-"
      << succs[i]->id () << "." << ctype2ext (ctype);
    ptr<merkle_tree> t = New refcounted<merkle_tree_disk> 
      (succtreepath, /* rw = */ false);
    trees.push_back (t);
    lastread.push_back (start);
    treedone.push_back (false);
  }
  
  repairs.setsize (0);
  while ((int) repairs.size () < count) {
    bool addedany = false;
    for (unsigned int i = 0; i < trees.size (); i++) {
      if (treedone[i]) continue;
      addedany = true;
      // Aim to read about one leaf page at a time.
      vec<chordID> keys = trees[i]->get_keyrange (lastread[i], stop, 64);
      if (keys.size () < 64)
	treedone[i] = true;
      for (unsigned int j = 0; i < keys.size (); i++) {
	keycounter *k = keymap[keys[j]];
	if (!k) {
	  k = New keycounter (keys[j]);
	  k->add (i);
	  keymap.insert (k);
	} else {
	  k->add (i);
	}
      }
      lastread[i] = incID (keys.back ());
    }
    // if we've read all the keys in the responsible range
    // in all trees, it's time to quit.
    if (!addedany)
      break;
    // Find the smallest range for which we have read everything
    chordID minimax = stop;
    for (unsigned int i = 0; i < trees.size (); i++)
      if (betweenleftincl (start, minimax, lastread[i]))
	minimax = lastread[i];

    keycounter *k = keymap.first ();
    while (k &&
	   between (start, minimax, k->id) &&
	   (int) repairs.size () < count)
    {
      if (k->count < (unsigned) thresh) {
	maint_repair_t repair;
	repair.id = k->id;
	unsigned int dst = k->firstvoid ();
	succs[dst]->fill_ipportvn (repair.machine_order_ipv4_addr,
	    repair.machine_order_port_vnnum);
	repairs.push_back (repair);
      }
      k = keymap.next (k);
    }
  }
  keymap.deleteall_correct ();
}
// How to figure out what the ip.port.vnnum is for a given tree?
// Build up trees from the recorded successor list which includes
// ip addresses.
// }}}
// {{{ Passing Tone
ref<maintainer> 
passingtone::produce_maintainer (str path, maint_dhashinfo_t *hostinfo, ptr<syncer> s)
{
  return New refcounted<passingtone> (path, hostinfo, s);
}

passingtone::passingtone (str path, maint_dhashinfo_t *hostinfo, ptr<syncer> s) :
  maintainer (path, hostinfo, s)
{
}

passingtone::~passingtone ()
{
}

void 
passingtone::handle_missing (ptr<locationcc> from,
    ptr<merkle_tree> t,
    bigint key, bool missing_local)
{
  if (missing_local) {
    // Enqueue a repair job to pull the object over locally.
  } else {
    // Enqueue a repair job to send the object to the remote side.
  }
}

TAMED void
passingtone::process_neighbors (
    const vec<ptr<locationcc> > &preds,
    const vec<ptr<locationcc> > &succs,
    cbv cb)
{
  // for key on succ/pred:
  //   if key in responsible range and not locally present:
  //     replicate key
  //

  // merkle_sync with succ and pred.  If any keys missing
  // locally, fetch them.
  cb ();
}
// }}}