---
title: Writing an bounded LRU Cache in Haskell
description: Using psqueues to write simple but fast code
tags: haskell
---

Introduction
============

In-memory caches form an important optimisation for modern applications. This
is one area where people often tend to write their own implementation (though
usually based on an existing idea). The reason for this is mostly that having a
one-size-fits all cache is really hard, and people often want to tune it for
performance reasons according to their usage pattern, or use a specific
interface that works really well for them.

However, this sometimes results in less-than-optimal design choices. I thought I
would take some time and explain how a bounded LRU Cache can be written in a
reasonably straightforward way (the code is fairly short), while still achieving
great performance. Hence, it should not be too much trouble to tune this code to
your needs.

The base for a bounded LRU Cache is usually a Priority Queue. We will use the
[psqueues](TODO) package, which provides Priority Search Queues. Priority Search
Queues are Priority Queues which have additional *lookup by key* functionality
-- so perfect for our cache lookups.

This blogpost is written in literate Haskell, so you should be able to plug it
into GHCi and play around with it -- the raw file can be found [here](TODO).

A pure implementation
=====================

We obviously needs some imports since, again, this is a literate Haskell file.

> {-# LANGUAGE BangPatterns #-}

> import           Control.Applicative     ((<$>))
> import           Data.Hashable           (Hashable, hash)
> import qualified Data.HashPSQ            as HashPSQ
> import           Data.Int                (Int64)
> import qualified Data.Vector as V
> import Data.IORef (IORef, newIORef, atomicModifyIORef')
> import Prelude hiding (lookup)
> import Data.Maybe (isNothing)

Let's start with our datatype definition. Our `Cache` is parameterized by type
over `k` and `v`, respecively our key and value types. We use the `k` and `v` as
key value types in our priority search queue, and as priority we are using an
`Int64`.

The `cTick` field represents a simple logical time value.

> data Cache k v = Cache
>     { cCapacity :: !Int
>     , cSize     :: !Int
>     , cTick     :: !Int64
>     , cQueue    :: !(HashPSQ.HashPSQ k Int64 v)
>     }

Creating an empty `Cache` is easy, we just need to know the maximum capacity:

> empty :: Int -> Cache k v
> empty capacity
>     | capacity < 1 = error "Cache.empty: capacity < 1"
>     | otherwise    = Cache
>         { cCapacity = capacity
>         , cSize     = 0
>         , cTick     = 0
>         , cQueue    = HashPSQ.empty
>         }

Next, we will write a utility function to ensure the invariants of our datatype.
We can then use that in our `lookup` and `insert` functions.

> trim :: (Hashable k, Ord k) => Cache k v -> Cache k v
> trim c

The first thing we want to check is if our logical time reaches the maximum
value it can take. If this is the case, can either reset all the ticks in our
queue, or we can clear it. We choose for the latter here, since that is simply
easier to code, and we are talking about a scenario that should not happen
often.

>     | cTick c >= maxBound    = empty (cCapacity c)

Then, we just need to check if our size is still within bounds. If it is not, we
drop the oldest item -- that is the item with the smallest tick.

>     | cSize c <= cCapacity c = c
>     | otherwise              = c
>         { cSize  = cSize c - 1
>         , cQueue = HashPSQ.deleteMin (cQueue c)
>         }

Insert is pretty straighforward to implement now. We use the `insertView`
function from `psqueues` which tells us whether or not an item was overwritten.

~~~~~~{.haskell}
insertView
  :: (Hashable k, Ord p, Ord k)
  => k -> p -> v -> HashPSQ k p v -> (Maybe (p, v), HashPSQ k p v)
~~~~~~

This is necessary, since we need to know whether or not we need to update
`cSize`.

> insert :: (Hashable k, Ord k) => k -> v -> Cache k v -> Cache k v
> insert k x c = trim $!
>     let (mbRemoved, q) = HashPSQ.insertView k (cTick c) x (cQueue c)
>     in c
>         { cSize  = if isNothing mbRemoved then cSize c + 1 else cSize c
>         , cTick  = cTick c + 1
>         , cQueue = q
>         }

Lookup is not that hard either, but we need to remember that in addition to
looking up the item, we also want to bump the priority. We can do this using the
`alter` function from psqueues: that allows to modify a value (bump its
priority) and return something (the value, if found) at the same time.

~~~~~{.haskell}
alter
    :: (Hashable k, Ord k, Ord p)
    => (Maybe (p, v) -> (b, Maybe (p, v)))
    -> k -> HashPSQ.HashPSQ k p v -> (b, HashPSQ.HashPSQ k p v)
~~~~~

The `b` in the signature above becomes our lookup result.

> lookup
>     :: (Hashable k, Ord k) => k -> Cache k v -> Maybe (v, Cache k v)
> lookup k c = case HashPSQ.alter lookupAndBump k (cQueue c) of
>     (Nothing, _) -> Nothing
>     (Just x, q)  ->
>         let !c' = trim $ c {cTick = cTick c + 1, cQueue = q}
>         in Just (x, c')
>   where
>     lookupAndBump Nothing       = (Nothing, Nothing)
>     lookupAndBump (Just (_, x)) = (Just x, Just ((cTick c), x))

That basically gives a clean and simple implementation of a pure LRU Cache. If
you are only writing pure code, you should be good to go! However, most
applications deal with caches in IO, so we will have a adjust for that.

A simple IO-based cache
=======================

Using an `IORef`, we can update our `Cache` to be easily usable in the IO Monad.

> newtype Handle k v = Handle (IORef (Cache k v))

Creating one is easy:

> newHandle :: Int -> IO (Handle k v)
> newHandle capacity = Handle <$> newIORef (empty capacity)

Our simple interface only needs to export one function. `cached` takes the key
of the value we are looking for, and an `IO` action which produces the value.
However, we will only actually execute this `IO` action if it is not present in
the cache.

> cached
>     :: (Hashable k, Ord k)
>     => Handle k v -> k -> IO v -> IO v
> cached (Handle ref) k io = do

First, we check the cache using our `lookup` function from above. This uses
`atomicModifyIORef'`, since our `lookup` might bump the priority of an item, and
in that case we modify the cache.

>     lookupRes <- atomicModifyIORef' ref $ \c -> case lookup k c of
>         Nothing      -> (c,  Nothing)
>         Just (v, c') -> (c', Just v)


If it is found, we can just return it.

>     case lookupRes of
>         Just v  -> return v

Otherwise, execute the `IO` action and call `atomicModifyIORef'` again to insert
it into the cache.

>         Nothing -> do
>             v <- io
>             atomicModifyIORef' ref $ \c -> (insert k v c, ())
>             return v

Contention
==========

This scheme already gives us fairly good performance. However, that can degrade
a little when lots of threads are calling `atomicModifyIORef'` on the same
`IORef`.

`atomicModifyIORef'` is implemented using a compare-and-swap, a bit like this:

~~~~~~{.haskell}
atomicModifyIORef' :: IORef a -> (a -> (a, b)) -> IO b
atomicModifyIORef' ref f = do
    x <- readIORef ref
    let (!y, !b) = f x
    swapped <- compareAndSwap ref x y  -- Only works if the value is still x
    if swapped
        then return b
        else atomicModifyIORef' ref f  -- Retry
~~~~~~

We can see that this can lead to contention: the more concurrent
`atomicModifyIORef'`s we get, the more retries, which will eventually bring our
performance to a grinding halt. This is a common problem with `IORef`s which I
have personaly encountered in real-world scenarios.

A striped cache
===============

A good solution around this problem, since we already have a `Hashable` instance
for our key anyway, is striping the keyspace. We can even reuse our `Handle` in
quite an elegant way. Instead of just using one `Handle`, we create a `Vector`
instead:

> newtype StripedHandle k v = StripedHandle (V.Vector (Handle k v))

The user can configure the number of handles that is created:

> newStripedHandle :: Int -> Int -> IO (StripedHandle k v)
> newStripedHandle numStripes capacityPerStripe =
>     StripedHandle <$> V.replicateM numStripes (newHandle capacityPerStripe)

Our hash function then determines which `Handle` we should use:

> stripedCached
>     :: (Hashable k, Ord k)
>     => StripedHandle k v -> k -> IO v -> IO v
> stripedCached (StripedHandle v) k =
>     cached (v V.! idx) k
>   where
>     idx = hash k `mod` V.length v

Conclusion
==========

We have implemented a common data structure, with two variations and decent
performance. Thanks to the psqueues package, the implementations are very
straightforward and should be possible to tune the caches to your need.
