//
//  ASDataController.mm
//  AsyncDisplayKit
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "ASDataController.h"

#import "ASAssert.h"
#import "ASCellNode.h"
#import "ASEnvironmentInternal.h"
#import "ASLayout.h"
#import "ASMainSerialQueue.h"
#import "ASMultidimensionalArrayUtils.h"
#import "ASThread.h"
#import "ASIndexedNodeContext.h"
#import "ASDataController+Subclasses.h"
#import "ASScope.h"

//#define LOG(...) NSLog(__VA_ARGS__)
#define LOG(...)

#define RETURN_IF_NO_DATASOURCE(val) if (self->_dataSource == nil) { return val; }
#define ASSERT_ON_EDITING_QUEUE ASDisplayNodeAssertNotNil(dispatch_get_specific(&kASDataControllerEditingQueueKey), @"%@ must be called on the editing transaction queue.", NSStringFromSelector(_cmd))

const static char * kASDataControllerEditingQueueKey = "kASDataControllerEditingQueueKey";
const static char * kASDataControllerEditingQueueContext = "kASDataControllerEditingQueueContext";

NSString * const ASDataControllerRowNodeKind = @"_ASDataControllerRowNodeKind";

@interface ASDataController () {
  NSMutableArray *_externalCompletedNodes;    // Main thread only.  External data access can immediately query this if available.
  NSMutableDictionary *_completedNodes;       // Main thread only.  External data access can immediately query this if _externalCompletedNodes is unavailable.
  NSMutableDictionary *_editingNodes;         // Modified on _editingTransactionQueue only.  Updates propagated to _completedNodes.
  BOOL _itemCountsFromDataSourceAreValid;     // Main thread only.
  std::vector<NSInteger> _itemCountsFromDataSource;         // Main thread only.
  
  ASMainSerialQueue *_mainSerialQueue;
  
  NSMutableArray *_pendingEditCommandBlocks;  // To be run on the main thread.  Handles begin/endUpdates tracking.
  dispatch_queue_t _editingTransactionQueue;  // Serial background queue.  Dispatches concurrent layout and manages _editingNodes.
  dispatch_group_t _editingTransactionGroup;     // Group of all edit transaction blocks. Useful for waiting.
  
  BOOL _initialReloadDataHasBeenCalled;

  BOOL _delegateDidInsertNodes;
  BOOL _delegateDidDeleteNodes;
  BOOL _delegateDidInsertSections;
  BOOL _delegateDidDeleteSections;
}

@property (nonatomic, assign) NSUInteger batchUpdateCounter;

@end

@implementation ASDataController

#pragma mark - Lifecycle

- (instancetype)initWithDataSource:(id<ASDataControllerSource>)dataSource
{
  if (!(self = [super init])) {
    return nil;
  }
  ASDisplayNodeAssert(![self isMemberOfClass:[ASDataController class]], @"ASDataController is an abstract class and should not be instantiated. Instantiate a subclass instead.");

  _dataSource = dataSource;

  _completedNodes = [NSMutableDictionary dictionary];
  _editingNodes = [NSMutableDictionary dictionary];

  _completedNodes[ASDataControllerRowNodeKind] = [NSMutableArray array];
  _editingNodes[ASDataControllerRowNodeKind] = [NSMutableArray array];
  
  _mainSerialQueue = [[ASMainSerialQueue alloc] init];
  
  _pendingEditCommandBlocks = [NSMutableArray array];
  
  const char *queueName = [[NSString stringWithFormat:@"org.AsyncDisplayKit.ASDataController.editingTransactionQueue:%p", self] cStringUsingEncoding:NSASCIIStringEncoding];
  _editingTransactionQueue = dispatch_queue_create(queueName, DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(_editingTransactionQueue, &kASDataControllerEditingQueueKey, &kASDataControllerEditingQueueContext, NULL);
  _editingTransactionGroup = dispatch_group_create();
  
  _batchUpdateCounter = 0;
  
  return self;
}

- (instancetype)init
{
  ASDisplayNodeFailAssert(@"Failed to call designated initializer.");
  id<ASDataControllerSource> fakeDataSource = nil;
  return [self initWithDataSource:fakeDataSource];
}

- (void)setDelegate:(id<ASDataControllerDelegate>)delegate
{
  if (_delegate == delegate) {
    return;
  }
  
  _delegate = delegate;
  
  // Interrogate our delegate to understand its capabilities, optimizing away expensive respondsToSelector: calls later.
  _delegateDidInsertNodes     = [_delegate respondsToSelector:@selector(dataController:didInsertNodes:atIndexPaths:withAnimationOptions:)];
  _delegateDidDeleteNodes     = [_delegate respondsToSelector:@selector(dataController:didDeleteNodes:atIndexPaths:withAnimationOptions:)];
  _delegateDidInsertSections  = [_delegate respondsToSelector:@selector(dataController:didInsertSections:atIndexSet:withAnimationOptions:)];
  _delegateDidDeleteSections  = [_delegate respondsToSelector:@selector(dataController:didDeleteSectionsAtIndexSet:withAnimationOptions:)];
}

+ (NSUInteger)parallelProcessorCount
{
  static NSUInteger parallelProcessorCount;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    parallelProcessorCount = [[NSProcessInfo processInfo] processorCount];
  });

  return parallelProcessorCount;
}

#pragma mark - Cell Layout

/**
 * Measures and defines the layout for each node in optimized batches on an editing queue, inserting the results into the backing store.
 */
- (void)_layoutNodesFromContexts:(NSArray<ASIndexedNodeContext *> *)contexts withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASSERT_ON_EDITING_QUEUE;
  
  NSUInteger nodeCount = contexts.count;
  if (nodeCount == 0) {
    return;
  }

  __strong NSIndexPath **allocatedContextIndexPaths = (__strong NSIndexPath **)calloc(nodeCount, sizeof(NSIndexPath *));
  __strong ASCellNode **allocatedNodeBuffer = (__strong ASCellNode **)calloc(nodeCount, sizeof(ASCellNode *));
  
  // TODO: Can we make this asynchronous, so that we don't retain self the whole time?
  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  dispatch_apply(nodeCount, queue, ^(size_t i) {
    RETURN_IF_NO_DATASOURCE();

    // Allocate the node.
    ASIndexedNodeContext *context = contexts[i];
    ASCellNode *node = [context allocateNode];
    if (node == nil) {
      ASDisplayNodeAssertNotNil(node, @"Node block created nil node; %@, %@", self, self.dataSource);
      node = [[ASCellNode alloc] init]; // Fallback to avoid crash for production apps.
    }
    
    // Measure the node.
    CGRect frame = CGRectZero;
    frame.size = [node measureWithSizeRange:context.constrainedSize].size;
    node.frame = frame;
    
    allocatedContextIndexPaths[i] = context.indexPath;
    allocatedNodeBuffer[i] = node;
  });

  BOOL canceled = _dataSource == nil;

  NSArray *allocatedNodes = nil;
  NSArray *indexPaths = nil;
  if (canceled == NO) {
    // Create nodes and indexPaths arrays
    allocatedNodes = [NSArray arrayWithObjects:allocatedNodeBuffer count:nodeCount];
    indexPaths = [NSArray arrayWithObjects:allocatedContextIndexPaths count:nodeCount];
  }
  
  // Nil out buffer indexes to allow arc to free the stored cells.
  for (int i = 0; i < nodeCount; i++) {
    allocatedContextIndexPaths[i] = nil;
    allocatedNodeBuffer[i] = nil;
  }
  free(allocatedContextIndexPaths);
  free(allocatedNodeBuffer);

  if (canceled == NO) {
    // Insert finished nodes into data storage
    [self _insertNodes:allocatedNodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
  }
}

- (ASSizeRange)constrainedSizeForNodeOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
  return [_dataSource dataController:self constrainedSizeForNodeAtIndexPath:indexPath];
}

#pragma mark - External Data Querying + Editing

- (void)insertNodes:(NSArray *)nodes ofKind:(NSString *)kind atIndexPaths:(NSArray *)indexPaths completion:(ASDataControllerCompletionBlock)completionBlock
{
  ASSERT_ON_EDITING_QUEUE;
  if (!indexPaths.count || _dataSource == nil) {
    return;
  }

  NSMutableArray *editingNodes = _editingNodes[kind];
  ASInsertElementsIntoMultidimensionalArrayAtIndexPaths(editingNodes, indexPaths, nodes);
  
  // Deep copy is critical here, or future edits to the sub-arrays will pollute state between _editing and _complete on different threads.
  NSMutableArray *completedNodes = ASTwoDimensionalArrayDeepMutableCopy(editingNodes);
  
  weakify(self);
  [_mainSerialQueue performBlockOnMainThread:^{
    strongifyOrExit(self);
    self->_completedNodes[kind] = completedNodes;
    if (completionBlock) {
      completionBlock(nodes, indexPaths);
    }
  }];
}

- (void)deleteNodesOfKind:(NSString *)kind atIndexPaths:(NSArray *)indexPaths completion:(ASDataControllerCompletionBlock)completionBlock
{
  if (!indexPaths.count || _dataSource == nil) {
    return;
  }

  LOG(@"_deleteNodesAtIndexPaths:%@ ofKind:%@, full index paths in _editingNodes = %@", indexPaths, kind, ASIndexPathsForTwoDimensionalArray(_editingNodes[kind]));
  NSMutableArray *editingNodes = _editingNodes[kind];
  ASDeleteElementsInMultidimensionalArrayAtIndexPaths(editingNodes, indexPaths);
  _editingNodes[kind] = editingNodes;

  weakify(self);
  [_mainSerialQueue performBlockOnMainThread:^{
    strongifyOrExit(self);
    NSMutableArray *allNodes = self->_completedNodes[kind];
    NSArray *nodes = ASFindElementsInMultidimensionalArrayAtIndexPaths(allNodes, indexPaths);
    ASDeleteElementsInMultidimensionalArrayAtIndexPaths(allNodes, indexPaths);
    if (completionBlock) {
      completionBlock(nodes, indexPaths);
    }
  }];
}

- (void)insertSections:(NSMutableArray *)sections ofKind:(NSString *)kind atIndexSet:(NSIndexSet *)indexSet completion:(void (^)(NSArray *sections, NSIndexSet *indexSet))completionBlock
{
  if (!indexSet.count|| _dataSource == nil) {
    return;
  }

  if (_editingNodes[kind] == nil) {
    _editingNodes[kind] = [NSMutableArray array];
  }
  
  [_editingNodes[kind] insertObjects:sections atIndexes:indexSet];
  
  // Deep copy is critical here, or future edits to the sub-arrays will pollute state between _editing and _complete on different threads.
  NSArray *sectionsForCompleted = ASTwoDimensionalArrayDeepMutableCopy(sections);
  
  weakify(self);
  [_mainSerialQueue performBlockOnMainThread:^{
    strongifyOrExit(self);
    [self->_completedNodes[kind] insertObjects:sectionsForCompleted atIndexes:indexSet];
    if (completionBlock) {
      completionBlock(sections, indexSet);
    }
  }];
}

- (void)deleteSectionsOfKind:(NSString *)kind atIndexSet:(NSIndexSet *)indexSet completion:(void (^)(NSIndexSet *indexSet))completionBlock
{
  if (!indexSet.count || _dataSource == nil) {
    return;
  }
  
  [_editingNodes[kind] removeObjectsAtIndexes:indexSet];
  weakify(self);
  [_mainSerialQueue performBlockOnMainThread:^{
    strongifyOrExit(self);
    [self->_completedNodes[kind] removeObjectsAtIndexes:indexSet];
    if (completionBlock) {
      completionBlock(indexSet);
    }
  }];
}

#pragma mark - Internal Data Querying + Editing

/**
 * Inserts the specified nodes into the given index paths and notifies the delegate of newly inserted nodes.
 *
 * @discussion Nodes are first inserted into the editing store, then the completed store is replaced by a deep copy
 * of the editing nodes. The delegate is invoked on the main thread.
 */
- (void)_insertNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASSERT_ON_EDITING_QUEUE;
  
  weakify(self);
  [self insertNodes:nodes ofKind:ASDataControllerRowNodeKind atIndexPaths:indexPaths completion:^(NSArray *nodes, NSArray *indexPaths) {
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    
    if (self->_delegateDidInsertNodes)
      [self->_delegate dataController:self didInsertNodes:nodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
  }];
}

/**
 * Removes the specified nodes at the given index paths and notifies the delegate of the nodes removed.
 *
 * @discussion Nodes are first removed from the editing store then removed from the completed store on the main thread.
 * Once the backing stores are consistent, the delegate is invoked on the main thread.
 */
- (void)_deleteNodesAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASSERT_ON_EDITING_QUEUE;
  
  weakify(self);
  [self deleteNodesOfKind:ASDataControllerRowNodeKind atIndexPaths:indexPaths completion:^(NSArray *nodes, NSArray *indexPaths) {
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    
    if (self->_delegateDidDeleteNodes)
      [self->_delegate dataController:self didDeleteNodes:nodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
  }];
}

/**
 * Inserts sections, represented as arrays, into the backing store at the given indices and notifies the delegate.
 *
 * @discussion The section arrays are inserted into the editing store, then a deep copy of the sections are inserted
 * in the completed store on the main thread. The delegate is invoked on the main thread.
 */
- (void)_insertSections:(NSMutableArray *)sections atIndexSet:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASSERT_ON_EDITING_QUEUE;
  
  weakify(self);
  [self insertSections:sections ofKind:ASDataControllerRowNodeKind atIndexSet:indexSet completion:^(NSArray *sections, NSIndexSet *indexSet) {
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    
    if (self->_delegateDidInsertSections)
      [self->_delegate dataController:self didInsertSections:sections atIndexSet:indexSet withAnimationOptions:animationOptions];
  }];
}

/**
 * Removes sections at the given indices from the backing store and notifies the delegate.
 *
 * @discussion Section array are first removed from the editing store, then the associated section in the completed
 * store is removed on the main thread. The delegate is invoked on the main thread.
 */
- (void)_deleteSectionsAtIndexSet:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASSERT_ON_EDITING_QUEUE;
  
  weakify(self);
  [self deleteSectionsOfKind:ASDataControllerRowNodeKind atIndexSet:indexSet completion:^(NSIndexSet *indexSet) {
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    
    if (self->_delegateDidDeleteSections)
      [self->_delegate dataController:self didDeleteSectionsAtIndexSet:indexSet withAnimationOptions:animationOptions];
  }];
}

#pragma mark - Initial Load & Full Reload (External API)

- (void)reloadDataWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions completion:(void (^)())completion
{
  [self _reloadDataWithAnimationOptions:animationOptions synchronously:NO completion:completion];
}

- (void)reloadDataImmediatelyWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self _reloadDataWithAnimationOptions:animationOptions synchronously:YES completion:nil];
}

- (void)_reloadDataWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions synchronously:(BOOL)synchronously completion:(void (^)())completion
{
  _initialReloadDataHasBeenCalled = YES;
  weakify(self);
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);

    NSUInteger sectionCount = [self->_dataSource numberOfSectionsInDataController:self];
    NSIndexSet *sectionIndexSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, sectionCount)];
    NSArray<ASIndexedNodeContext *> *contexts = [self _populateFromDataSourceWithSectionIndexSet:sectionIndexSet];

    [self invalidateDataSourceItemCounts];
    // Fetch the new item counts upfront.
    [self itemCountsFromDataSource];
    
    // Allow subclasses to perform setup before going into the edit transaction
    [self prepareForReloadData];
    
    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      LOG(@"Edit Transaction - reloadData");
      
      // Remove everything that existed before the reload, now that we're ready to insert replacements
      NSMutableArray *editingNodes = self->_editingNodes[ASDataControllerRowNodeKind];
      NSUInteger editingNodesSectionCount = editingNodes.count;
      
      if (editingNodesSectionCount) {
        NSIndexSet *indexSet = [[NSIndexSet alloc] initWithIndexesInRange:NSMakeRange(0, editingNodesSectionCount)];
        [self _deleteNodesAtIndexPaths:ASIndexPathsForTwoDimensionalArray(editingNodes) withAnimationOptions:animationOptions];
        [self _deleteSectionsAtIndexSet:indexSet withAnimationOptions:animationOptions];
      }
      
      [self willReloadData];
      
      // Insert empty sections
      NSMutableArray *sections = [NSMutableArray arrayWithCapacity:sectionCount];
      for (int i = 0; i < sectionCount; i++) {
        [sections addObject:[[NSMutableArray alloc] init]];
      }
      [self _insertSections:sections atIndexSet:sectionIndexSet withAnimationOptions:animationOptions];

      [self _layoutNodesFromContexts:contexts withAnimationOptions:animationOptions];

      if (completion) {
        dispatch_async(dispatch_get_main_queue(), completion);
      }
    });
    if (synchronously) {
      [self waitUntilAllUpdatesAreCommitted];
    }
  }];
}

- (void)waitUntilAllUpdatesAreCommitted
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(_batchUpdateCounter == 0, @"Should not be called between beginUpdate or endUpdate");
  
  // This should never be called in a batch update, return immediately therefore
  if (_batchUpdateCounter > 0) { return; }
  
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);
  
  // Schedule block in main serial queue to wait until all operations are finished that are
  // where scheduled while waiting for the _editingTransactionQueue to finish
  [_mainSerialQueue performBlockOnMainThread:^{ }];
}

#pragma mark - Data Source Access (Calling _dataSource)

/**
 * Fetches row contexts for the provided sections from the data source.
 */
- (NSArray<ASIndexedNodeContext *> *)_populateFromDataSourceWithSectionIndexSet:(NSIndexSet *)indexSet
{
  ASDisplayNodeAssertMainThread();
  
  id<ASEnvironment> environment = [self.environmentDelegate dataControllerEnvironment];
  ASEnvironmentTraitCollection environmentTraitCollection = environment.environmentTraitCollection;
  
  NSMutableArray<ASIndexedNodeContext *> *contexts = [NSMutableArray array];
  [indexSet enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
    for (NSUInteger sectionIndex = range.location; sectionIndex < NSMaxRange(range); sectionIndex++) {
      NSUInteger itemCount = [_dataSource dataController:self rowsInSection:sectionIndex];
      for (NSUInteger i = 0; i < itemCount; i++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:i inSection:sectionIndex];
        ASCellNodeBlock nodeBlock = [_dataSource dataController:self nodeBlockAtIndexPath:indexPath];
        
        ASSizeRange constrainedSize = [self constrainedSizeForNodeOfKind:ASDataControllerRowNodeKind atIndexPath:indexPath];
        [contexts addObject:[[ASIndexedNodeContext alloc] initWithNodeBlock:nodeBlock
                                                                  indexPath:indexPath
                                                            constrainedSize:constrainedSize
                                                 environmentTraitCollection:environmentTraitCollection]];
      }
    }
  }];
  return contexts;
}

- (void)invalidateDataSourceItemCounts
{
  ASDisplayNodeAssertMainThread();
  _itemCountsFromDataSourceAreValid = NO;
}

- (std::vector<NSInteger>)itemCountsFromDataSource
{
  ASDisplayNodeAssertMainThread();
  if (NO == _itemCountsFromDataSourceAreValid) {
    id<ASDataControllerSource> source = self.dataSource;
    NSInteger sectionCount = [source numberOfSectionsInDataController:self];
    std::vector<NSInteger> newCounts;
    newCounts.reserve(sectionCount);
    for (NSInteger i = 0; i < sectionCount; i++) {
      newCounts.push_back([source dataController:self rowsInSection:i]);
    }
    _itemCountsFromDataSource = newCounts;
    _itemCountsFromDataSourceAreValid = YES;
  }
  return _itemCountsFromDataSource;
}

#pragma mark - Batching (External API)

- (void)beginUpdates
{
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);
  // Begin queuing up edit calls that happen on the main thread.
  // This will prevent further operations from being scheduled on _editingTransactionQueue.
  _batchUpdateCounter++;
}

- (void)endUpdates
{
  [self endUpdatesAnimated:YES completion:nil];
}

- (void)endUpdatesAnimated:(BOOL)animated completion:(void (^)(BOOL))completion
{
  _batchUpdateCounter--;

  if (_batchUpdateCounter == 0) {
    LOG(@"endUpdatesWithCompletion - beginning");

    weakify(self);
    dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self->_mainSerialQueue performBlockOnMainThread:^{
        strongifyOrExit(self);
        // Deep copy _completedNodes to _externalCompletedNodes.
        // Any external queries from now on will be done on _externalCompletedNodes, to guarantee data consistency with the delegate.
        self->_externalCompletedNodes = ASTwoDimensionalArrayDeepMutableCopy(self->_completedNodes[ASDataControllerRowNodeKind]);

        LOG(@"endUpdatesWithCompletion - begin updates call to delegate");
        [self->_delegate dataControllerBeginUpdates:self];
      }];
    });

    // Running these commands may result in blocking on an _editingTransactionQueue operation that started even before -beginUpdates.
    // Each subsequent command in the queue will also wait on the full asynchronous completion of the prior command's edit transaction.
    LOG(@"endUpdatesWithCompletion - %zd blocks to run", _pendingEditCommandBlocks.count);
    NSUInteger i = 0;
    for (dispatch_block_t block in _pendingEditCommandBlocks) {
      LOG(@"endUpdatesWithCompletion - running block #%zd", i);
      block();
      i += 1;
    }
    [_pendingEditCommandBlocks removeAllObjects];
    dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self->_mainSerialQueue performBlockOnMainThread:^{
        strongifyOrExit(self);
        // Now that the transaction is done, _completedNodes can be accessed externally again.
        self->_externalCompletedNodes = nil;
        
        LOG(@"endUpdatesWithCompletion - calling delegate end");
        [self->_delegate dataController:self endUpdatesAnimated:animated completion:completion];
      }];
    });
  }
}

/**
 * Queues the given operation until an `endUpdates` synchronize update is completed.
 *
 * If this method is called outside of a begin/endUpdates batch update, the block is
 * executed immediately.
 */
- (void)performEditCommandWithBlock:(void (^)(void))block
{
  // This method needs to block the thread and synchronously perform the operation if we are not
  // queuing commands for begin/endUpdates.  If we are queuing, it needs to return immediately.
  if (!_initialReloadDataHasBeenCalled) {
    return;
  }
  
  if (block == nil) {
    return;
  }
  
  // If we have never performed a reload, there is no value in executing edit operations as the initial
  // reload will directly re-query the latest state of the datasource - so completely skip the block in this case.
  if (_batchUpdateCounter == 0) {
    block();
  } else {
    [_pendingEditCommandBlocks addObject:block];
  }
}

#pragma mark - Section Editing (External API)

- (void)insertSections:(NSIndexSet *)sections withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  weakify(self);
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    LOG(@"Edit Command - insertSections: %@", sections);
    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);
    
    NSArray<ASIndexedNodeContext *> *contexts = [self _populateFromDataSourceWithSectionIndexSet:sections];

    [self prepareForInsertSections:sections];
    
    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self willInsertSections:sections];

      LOG(@"Edit Transaction - insertSections: %@", sections);
      NSMutableArray *sectionArray = [NSMutableArray arrayWithCapacity:sections.count];
      for (NSUInteger i = 0; i < sections.count; i++) {
        [sectionArray addObject:[NSMutableArray array]];
      }

      [self _insertSections:sectionArray atIndexSet:sections withAnimationOptions:animationOptions];
      
      [self _layoutNodesFromContexts:contexts withAnimationOptions:animationOptions];
    });
  }];
}

- (void)deleteSections:(NSIndexSet *)sections withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  weakify(self);
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    LOG(@"Edit Command - deleteSections: %@", sections);
    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);
    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self willDeleteSections:sections];

      // remove elements
      LOG(@"Edit Transaction - deleteSections: %@", sections);
      NSArray *indexPaths = ASIndexPathsForMultidimensionalArrayAtIndexSet(self->_editingNodes[ASDataControllerRowNodeKind], sections);
      
      [self _deleteNodesAtIndexPaths:indexPaths withAnimationOptions:animationOptions];
      [self _deleteSectionsAtIndexSet:sections withAnimationOptions:animationOptions];
    });
  }];
}

- (void)reloadSections:(NSIndexSet *)sections withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssert(NO, @"ASDataController does not support %@. Call this on ASChangeSetDataController the reload will be broken into delete & insert.", NSStringFromSelector(_cmd));
}

- (void)moveSection:(NSInteger)section toSection:(NSInteger)newSection withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  weakify(self);
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    LOG(@"Edit Command - moveSection");

    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);
    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self willMoveSection:section toSection:newSection];

      // remove elements
      
      LOG(@"Edit Transaction - moveSection");
      NSMutableArray *editingRows = self->_editingNodes[ASDataControllerRowNodeKind];
      NSArray *indexPaths = ASIndexPathsForMultidimensionalArrayAtIndexSet(editingRows, [NSIndexSet indexSetWithIndex:section]);
      NSArray *nodes = ASFindElementsInMultidimensionalArrayAtIndexPaths(editingRows, indexPaths);
      [self _deleteNodesAtIndexPaths:indexPaths withAnimationOptions:animationOptions];

      // update the section of indexpaths
      NSMutableArray *updatedIndexPaths = [[NSMutableArray alloc] initWithCapacity:indexPaths.count];
      for (NSIndexPath *indexPath in indexPaths) {
        NSIndexPath *updatedIndexPath = [NSIndexPath indexPathForItem:indexPath.item inSection:newSection];
        [updatedIndexPaths addObject:updatedIndexPath];
      }

      // Don't re-calculate size for moving
      [self _insertNodes:nodes atIndexPaths:updatedIndexPaths withAnimationOptions:animationOptions];
    });
  }];
}


#pragma mark - Backing store manipulation optional hooks (Subclass API)

- (void)prepareForReloadData
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willReloadData
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)prepareForInsertSections:(NSIndexSet *)sections
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willInsertSections:(NSIndexSet *)sections
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willDeleteSections:(NSIndexSet *)sections
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willMoveSection:(NSInteger)section toSection:(NSInteger)newSection
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)prepareForInsertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willInsertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)prepareForDeleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willDeleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

#pragma mark - Row Editing (External API)

- (void)insertRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  weakify(self);
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    LOG(@"Edit Command - insertRows: %@", indexPaths);
    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);

    // Sort indexPath to avoid messing up the index when inserting in several batches
    NSArray *sortedIndexPaths = [indexPaths sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<ASIndexedNodeContext *> *contexts = [[NSMutableArray alloc] initWithCapacity:indexPaths.count];

    id<ASEnvironment> environment = [self.environmentDelegate dataControllerEnvironment];
    ASEnvironmentTraitCollection environmentTraitCollection = environment.environmentTraitCollection;
    
    for (NSIndexPath *indexPath in sortedIndexPaths) {
      ASCellNodeBlock nodeBlock = [self->_dataSource dataController:self nodeBlockAtIndexPath:indexPath];
      ASSizeRange constrainedSize = [self constrainedSizeForNodeOfKind:ASDataControllerRowNodeKind atIndexPath:indexPath];
      [contexts addObject:[[ASIndexedNodeContext alloc] initWithNodeBlock:nodeBlock
                                                                indexPath:indexPath
                                                          constrainedSize:constrainedSize
                                               environmentTraitCollection:environmentTraitCollection]];
    }

    [self prepareForInsertRowsAtIndexPaths:indexPaths];

    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self willInsertRowsAtIndexPaths:indexPaths];

      LOG(@"Edit Transaction - insertRows: %@", indexPaths);
      [self _layoutNodesFromContexts:contexts withAnimationOptions:animationOptions];
    });
  }];
}

- (void)deleteRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  weakify(self);
  [self performEditCommandWithBlock:^{
    strongifyOrExit(self);
    ASDisplayNodeAssertMainThread();
    LOG(@"Edit Command - deleteRows: %@", indexPaths);

    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);
    
    // Sort indexPath in order to avoid messing up the index when deleting in several batches.
    // FIXME: Shouldn't deletes be sorted in descending order?
    NSArray *sortedIndexPaths = [indexPaths sortedArrayUsingSelector:@selector(compare:)];

    [self prepareForDeleteRowsAtIndexPaths:sortedIndexPaths];

    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self willDeleteRowsAtIndexPaths:sortedIndexPaths];

      LOG(@"Edit Transaction - deleteRows: %@", indexPaths);
      [self _deleteNodesAtIndexPaths:sortedIndexPaths withAnimationOptions:animationOptions];
    });
  }];
}

- (void)reloadRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssert(NO, @"ASDataController does not support %@. Call this on ASChangeSetDataController and the reload will be broken into delete & insert.", NSStringFromSelector(_cmd));
}

- (void)relayoutAllNodes
{
  weakify(self);
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    LOG(@"Edit Command - relayoutRows");
    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);

    // Can't relayout right away because _completedNodes may not be up-to-date,
    // i.e there might be some nodes that were measured using the old constrained size but haven't been added to _completedNodes
    // (see _layoutNodes:atIndexPaths:withAnimationOptions:).
    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      [self->_mainSerialQueue performBlockOnMainThread:^{
        for (NSString *kind in self->_completedNodes) {
          [self _relayoutNodesOfKind:kind];
        }
      }];
    });
  }];
}

- (void)_relayoutNodesOfKind:(NSString *)kind
{
  ASDisplayNodeAssertMainThread();
  NSArray *nodes = [self completedNodesOfKind:kind];
  if (!nodes.count) {
    return;
  }
  
  NSUInteger sectionIndex = 0;
  for (NSMutableArray *section in nodes) {
    NSUInteger rowIndex = 0;
    for (ASCellNode *node in section) {
      NSIndexPath *indexPath = [NSIndexPath indexPathForRow:rowIndex inSection:sectionIndex];
      ASSizeRange constrainedSize = [self constrainedSizeForNodeOfKind:kind atIndexPath:indexPath];
      CGRect frame = CGRectZero;
      frame.size = [node measureWithSizeRange:constrainedSize].size;
      node.frame = frame;
      rowIndex += 1;
    }
    sectionIndex += 1;
  }
}

- (void)moveRowAtIndexPath:(NSIndexPath *)indexPath toIndexPath:(NSIndexPath *)newIndexPath withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  weakify(self);
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    strongifyOrExit(self);
    LOG(@"Edit Command - moveRow: %@ > %@", indexPath, newIndexPath);
    dispatch_group_wait(self->_editingTransactionGroup, DISPATCH_TIME_FOREVER);
    
    dispatch_group_async(self->_editingTransactionGroup, self->_editingTransactionQueue, ^{
      strongifyOrExit(self);
      LOG(@"Edit Transaction - moveRow: %@ > %@", indexPath, newIndexPath);
      NSArray *indexPaths = @[indexPath];
      NSArray *nodes = ASFindElementsInMultidimensionalArrayAtIndexPaths(self->_editingNodes[ASDataControllerRowNodeKind], indexPaths);
      [self _deleteNodesAtIndexPaths:indexPaths withAnimationOptions:animationOptions];

      // Don't re-calculate size for moving
      NSArray *newIndexPaths = @[newIndexPath];
      [self _insertNodes:nodes atIndexPaths:newIndexPaths withAnimationOptions:animationOptions];
    });
  }];
}

#pragma mark - Data Querying (Subclass API)

- (NSArray *)indexPathsForEditingNodesOfKind:(NSString *)kind
{
  NSArray *nodes = _editingNodes[kind];
  return nodes != nil ? ASIndexPathsForTwoDimensionalArray(nodes) : nil;
}

- (NSMutableArray *)editingNodesOfKind:(NSString *)kind
{
  return _editingNodes[kind] ? : [NSMutableArray array];
}

- (NSMutableArray *)completedNodesOfKind:(NSString *)kind
{
  return _completedNodes[kind];
}

#pragma mark - Data Querying (External API)

- (NSUInteger)numberOfSections
{
  ASDisplayNodeAssertMainThread();
  return [[self completedNodes] count];
}

- (NSUInteger)numberOfRowsInSection:(NSUInteger)section
{
  ASDisplayNodeAssertMainThread();
  NSArray *completedNodes = [self completedNodes];
  return (section < completedNodes.count) ? [completedNodes[section] count] : 0;
}

- (ASCellNode *)nodeAtIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  
  NSArray *completedNodes = [self completedNodes];
  NSInteger section = indexPath.section;
  NSInteger row = indexPath.row;
  ASCellNode *node = nil;
  
  if (section >= 0 && row >= 0 && section < completedNodes.count) {
    NSArray *completedNodesSection = completedNodes[section];
    if (row < completedNodesSection.count) {
      node = completedNodesSection[row];
    }
  }
  
  return node;
}

- (NSIndexPath *)indexPathForNode:(ASCellNode *)cellNode;
{
  ASDisplayNodeAssertMainThread();
  
  NSInteger section = 0;
  // Loop through each section to look for the cellNode
  for (NSArray *sectionNodes in [self completedNodes]) {
    NSUInteger item = [sectionNodes indexOfObjectIdenticalTo:cellNode];
    if (item != NSNotFound) {
      return [NSIndexPath indexPathForItem:item inSection:section];
    }
    section += 1;
  }
  
  return nil;
}

/// Returns nodes that can be queried externally. _externalCompletedNodes is used if available, _completedNodes otherwise.
- (NSArray *)completedNodes
{
  ASDisplayNodeAssertMainThread();
  return _externalCompletedNodes ? : _completedNodes[ASDataControllerRowNodeKind];
}

#pragma mark - Dealloc

- (void)dealloc
{
  ASDisplayNodeAssertMainThread();
  for (NSMutableArray *sections in [_completedNodes objectEnumerator]) {
    for (NSArray *section in sections) {
      for (ASCellNode *node in section) {
        if (node.isNodeLoaded) {
          if (node.layerBacked) {
            [node.layer removeFromSuperlayer];
          } else {
            [node.view removeFromSuperview];
          }
        }
      }
    }
  }
}

@end
