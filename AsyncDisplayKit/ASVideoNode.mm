/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ASVideoNode.h"
#import "ASDefaultPlayButton.h"

@interface ASVideoNode ()
{
  ASDN::RecursiveMutex _videoLock;
  
  __weak id<ASVideoNodeDelegate> _delegate;
  
  BOOL _shouldBePlaying;
  
  BOOL _shouldAutorepeat;
  BOOL _shouldAutoplay;
  
  BOOL _muted;
  
  AVAsset *_asset;
  NSURL *_url;
  
  AVPlayerItem *_currentPlayerItem;
  AVPlayer *_player;
  
  ASImageNode *_placeholderImageNode;
  
  ASButtonNode *_playButton;
  ASDisplayNode *_playerNode;
  ASDisplayNode *_spinner;
  NSString *_gravity;
  
  dispatch_queue_t _previewQueue;
  dispatch_queue_t _progressQueue;
  
  id _periodicTimeObserver;
}

@end

@implementation ASVideoNode

//TODO: Have a bash at supplying a preview image node for use with HLS videos as we can't have a priview with those


#pragma mark - Construction and Layout

- (instancetype)init
{
	_previewQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
  _progressQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  _shouldObserveInterfaceStateChanges = YES;
  
  self.playButton = [[ASDefaultPlayButton alloc] init];
  self.gravity = AVLayerVideoGravityResizeAspect;
  [self addTarget:self action:@selector(tapped) forControlEvents:ASControlNodeEventTouchUpInside];
  
  return self;
}

- (instancetype)initWithViewBlock:(ASDisplayNodeViewBlock)viewBlock didLoadBlock:(ASDisplayNodeDidLoadBlock)didLoadBlock
{
  ASDisplayNodeAssertNotSupported();
  return nil;
}

- (ASDisplayNode*)constructPlayerNode
{
  ASDisplayNode* playerNode = [[ASDisplayNode alloc] initWithLayerBlock:^CALayer *{
    AVPlayerLayer *playerLayer = [[AVPlayerLayer alloc] init];
    if (!_player) {
      [self constructCurrentPlayerItemFromInitData];
      _player = [AVPlayer playerWithPlayerItem:_currentPlayerItem];
      _player.muted = _muted;
      
      __weak __typeof__(self) weakSelf = self;
      _periodicTimeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 15) queue:_progressQueue usingBlock:^(CMTime time) {
        __typeof__(self) strongSelf = weakSelf;
        if ([strongSelf.delegate respondsToSelector:@selector(videoNodeDidUpdateProgressWithCurrentTime:duration:)]) {
          CMTime duration = [strongSelf.player.currentItem duration];
          [strongSelf.delegate videoNodeDidUpdateProgressWithCurrentTime:time duration:duration];
        }
      }];
    }
    playerLayer.player = _player;
    playerLayer.videoGravity = [self gravity];
    return playerLayer;
  }];
  
  return playerNode;
}

- (void)constructCurrentPlayerItemFromInitData
{
  ASDisplayNodeAssert(_asset || _url, @"ASVideoNode must be initialised with either an AVAsset or URL");
  [self removePlayerItemObservers];
  
  if (_asset) {
    _currentPlayerItem = [[AVPlayerItem alloc] initWithAsset:_asset];
  } else if (_url) {
    _currentPlayerItem = [[AVPlayerItem alloc] initWithURL:_url];
  }

  if (_currentPlayerItem) {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:_currentPlayerItem];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(errorWhilePlaying:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:_currentPlayerItem];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(errorWhilePlaying:) name:AVPlayerItemNewErrorLogEntryNotification object:_currentPlayerItem];
  }
}

- (void)removePlayerItemObservers
{
  if (_currentPlayerItem) {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewErrorLogEntryNotification object:nil];
  }
}

- (void)didLoad
{
  [super didLoad];
  
  if (_shouldBePlaying) {
    _playerNode = [self constructPlayerNode];
    [self insertSubnode:_playerNode atIndex:0];
  } else if (_asset) {
    [self setPlaceholderImagefromAsset:_asset];
  }
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)layout
{
  [super layout];
  
  CGRect bounds = self.bounds;
  
  _placeholderImageNode.frame = bounds;
  _playerNode.frame = bounds;
  _playerNode.layer.frame = bounds;
  
  _playButton.frame = bounds;
  
  CGFloat horizontalDiff = (bounds.size.width - _playButton.bounds.size.width)/2;
  CGFloat verticalDiff = (bounds.size.height - _playButton.bounds.size.height)/2;
  _playButton.hitTestSlop = UIEdgeInsetsMake(-verticalDiff, -horizontalDiff, -verticalDiff, -horizontalDiff);
  
  _spinner.bounds = CGRectMake(0, 0, 44, 44);
  _spinner.position = CGPointMake(bounds.size.width/2, bounds.size.height/2);
}

- (void)setPlaceholderImagefromAsset:(AVAsset*)asset
{
  ASDN::MutexLocker l(_videoLock);
  if (!_placeholderImageNode)
    _placeholderImageNode = [[ASImageNode alloc] init];
  
  dispatch_async(_previewQueue, ^{
    AVAssetImageGenerator *imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:_asset];
    imageGenerator.appliesPreferredTrackTransform = YES;
    NSArray *times = @[[NSValue valueWithCMTime:CMTimeMake(0, 1)]];
    
    [imageGenerator generateCGImagesAsynchronouslyForTimes:times completionHandler:^(CMTime requestedTime, CGImageRef  _Nullable image, CMTime actualTime, AVAssetImageGeneratorResult result, NSError * _Nullable error) {
      
      // Unfortunately it's not possible to generate a preview image for an HTTP live stream asset, so we'll give up here
      // http://stackoverflow.com/questions/32112205/m3u8-file-avassetimagegenerator-error
      if (image && _placeholderImageNode.image == nil) {
        UIImage *theImage = [UIImage imageWithCGImage:image];
        
        _placeholderImageNode = [[ASImageNode alloc] init];
        _placeholderImageNode.layerBacked = YES;
        _placeholderImageNode.image = theImage;
        
        if ([_gravity isEqualToString:AVLayerVideoGravityResize]) {
          _placeholderImageNode.contentMode = UIViewContentModeRedraw;
        }
        if ([_gravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
          _placeholderImageNode.contentMode = UIViewContentModeScaleAspectFit;
        }
        if ([_gravity isEqual:AVLayerVideoGravityResizeAspectFill]) {
          _placeholderImageNode.contentMode = UIViewContentModeScaleAspectFill;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
          _placeholderImageNode.frame = self.bounds;
          [self insertSubnode:_placeholderImageNode atIndex:0];
        });
      }
    }];
  });
}

- (void)interfaceStateDidChange:(ASInterfaceState)newState fromState:(ASInterfaceState)oldState
{
  [super interfaceStateDidChange:newState fromState:oldState];
	
	BOOL nowVisible = ASInterfaceStateIncludesVisible(newState);
	BOOL wasVisible = ASInterfaceStateIncludesVisible(oldState);

  if (!nowVisible) {
    if (wasVisible) {
      if (_shouldBePlaying && _shouldObserveInterfaceStateChanges) {
        [self pause];
        _shouldBePlaying = YES;
      }
      if (_shouldObserveInterfaceStateChanges) {
        [(UIActivityIndicatorView *)_spinner.view stopAnimating];
        [_spinner removeFromSupernode];
      }
    }
  } else {
    if (_shouldBePlaying) {
      [self play];
    }
  }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
  if (object == _currentPlayerItem && [keyPath isEqualToString:@"status"]) {
    if (_currentPlayerItem.status == AVPlayerItemStatusReadyToPlay) {
      if ([self.subnodes containsObject:_spinner]) {
        [_spinner removeFromSupernode];
        _spinner = nil;
      }
      
      // If we don't yet have a placeholder image update it now that we should have data available for it
      if (!_placeholderImageNode) {
        if (_currentPlayerItem &&
            _currentPlayerItem.tracks.count > 0 &&
            _currentPlayerItem.tracks[0].assetTrack &&
            _currentPlayerItem.tracks[0].assetTrack.asset) {
          _asset = _currentPlayerItem.tracks[0].assetTrack.asset;
          [self setPlaceholderImagefromAsset:_asset];
          [self setNeedsLayout];
        }
      }
			
    } else if (_currentPlayerItem.status == AVPlayerItemStatusFailed) {
      
    }
  }
}

- (void)tapped
{
  if (self.delegate && [self.delegate respondsToSelector:@selector(videoNodeWasTapped:)]) {
    [self.delegate videoNodeWasTapped:self];
  } else {
    if (_shouldBePlaying) {
      [self pause];
    } else {
      [self play];
    }
  }
}

- (void)fetchData
{
  [super fetchData];
  
  @try {
    [_currentPlayerItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(status))];
  }
  @catch (NSException * __unused exception) {
    NSLog(@"unnecessary removal in fetch data");
  }
  
  {
    ASDN::MutexLocker l(_videoLock);
    [self constructCurrentPlayerItemFromInitData];
    [_currentPlayerItem addObserver:self forKeyPath:NSStringFromSelector(@selector(status)) options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    
    if (_player) {
      [_player replaceCurrentItemWithPlayerItem:_currentPlayerItem];
    } else {
      _player = [[AVPlayer alloc] initWithPlayerItem:_currentPlayerItem];
      _player.muted = _muted;
      
      __weak __typeof__(self) weakSelf = self;
      _periodicTimeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 15) queue:_progressQueue usingBlock:^(CMTime time) {
        __typeof__(self) strongSelf = weakSelf;
        if ([strongSelf.delegate respondsToSelector:@selector(videoNodeDidUpdateProgressWithCurrentTime:duration:)]) {
          CMTime duration = [strongSelf.player.currentItem duration];
          [strongSelf.delegate videoNodeDidUpdateProgressWithCurrentTime:time duration:duration];
        }
      }];
    }
  }
}

- (void)startLoader
{
  [(UIActivityIndicatorView *)_spinner.view startAnimating];
}

- (void)stopLoader
{
  if (_spinner) {
    [(UIActivityIndicatorView *)_spinner.view stopAnimating];
    [_spinner removeFromSupernode];
    _spinner = nil;
  }
}

- (void)clearFetchedData
{
  [super clearFetchedData];
  
  {
    ASDN::MutexLocker l(_videoLock);
    ((AVPlayerLayer *)_playerNode.layer).player = nil;
    _player = nil;
    _placeholderImageNode.image = nil;
  }
}

- (void)visibilityDidChange:(BOOL)isVisible
{
  [super visibilityDidChange:isVisible];
  
  ASDN::MutexLocker l(_videoLock);
  
  if (_shouldAutoplay && _playerNode.isNodeLoaded) {
    [self play];
  } else if (_shouldAutoplay) {
    _shouldBePlaying = YES;
  }
  if (isVisible) {
    if (_playerNode.isNodeLoaded) {
      if (!_player) {
        [self constructCurrentPlayerItemFromInitData];
        _player = [AVPlayer playerWithPlayerItem:_currentPlayerItem];
        _player.muted = _muted;
        
        __weak __typeof__(self) weakSelf = self;
        _periodicTimeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 15) queue:_progressQueue usingBlock:^(CMTime time) {
          __typeof__(self) strongSelf = weakSelf;
          if ([strongSelf.delegate respondsToSelector:@selector(videoNodeDidUpdateProgressWithCurrentTime:duration:)]) {
            CMTime duration = [strongSelf.player.currentItem duration];
            [strongSelf.delegate videoNodeDidUpdateProgressWithCurrentTime:time duration:duration];
          }
        }];
      }
      ((AVPlayerLayer *)_playerNode.layer).player = _player;
    }
    
    if (_shouldBePlaying) {
      [self play];
    }
  }
}


#pragma mark - Video Properties

- (void)setPlayButton:(ASButtonNode *)playButton
{
  ASDN::MutexLocker l(_videoLock);
  
  _playButton = playButton;
  
  [self addSubnode:playButton];
  
  [_playButton addTarget:self action:@selector(tapped) forControlEvents:ASControlNodeEventTouchUpInside];
}

- (ASButtonNode *)playButton
{
  ASDN::MutexLocker l(_videoLock);
  
  return _playButton;
}

- (void)setAsset:(AVAsset *)asset
{
  ASDN::MutexLocker l(_videoLock);
  
  if (ASObjectIsEqual(asset, _asset)
      || ([asset isKindOfClass:[AVURLAsset class]]
          && [_asset isKindOfClass:[AVURLAsset class]]
          && ASObjectIsEqual(((AVURLAsset *)asset).URL, ((AVURLAsset *)_asset).URL))) {
        return;
      }
  
  _asset = asset;
  
  // FIXME: Adopt -setNeedsFetchData when it is available
  if (self.interfaceState & ASInterfaceStateFetchData) {
    [self fetchData];
  }
}

- (AVAsset *)asset
{
  ASDN::MutexLocker l(_videoLock);
  return _asset;
}

- (void)setUrl:(NSURL *)url
{
	ASDN::MutexLocker l(_videoLock);
	
	if (ASObjectIsEqual(url, _url))
		return;
	
	_url = url;
	
	// FIXME: Adopt -setNeedsFetchData when it is available
	if (self.interfaceState & ASInterfaceStateFetchData) {
		[self fetchData];
	}
}

- (NSURL *)url
{
	ASDN::MutexLocker l(_videoLock);
	return _url;
}

- (AVPlayer *)player
{
  ASDN::MutexLocker l(_videoLock);
  return _player;
}

- (void)setGravity:(NSString *)gravity
{
  ASDN::MutexLocker l(_videoLock);
  if (_playerNode.isNodeLoaded) {
    ((AVPlayerLayer *)_playerNode.layer).videoGravity = gravity;
  }
  _gravity = gravity;
}

- (NSString *)gravity
{
  ASDN::MutexLocker l(_videoLock);
  
  return _gravity;
}

- (BOOL)muted
{
  ASDN::MutexLocker l(_videoLock);
  
  return _muted;
}

- (void)setMuted:(BOOL)muted
{
  ASDN::MutexLocker l(_videoLock);
  
  _player.muted = muted;
  _muted = muted;
}

#pragma mark - Video Playback

- (void)play
{
  ASDN::MutexLocker l(_videoLock);
  
  if (!_spinner) {
    _spinner = [[ASDisplayNode alloc] initWithViewBlock:^UIView *{
      UIActivityIndicatorView *spinnnerView = [[UIActivityIndicatorView alloc] init];
      spinnnerView.hidesWhenStopped = YES;
      spinnnerView.color = [UIColor whiteColor];
      
      return spinnnerView;
    }];
  }
  
  if (!_playerNode) {
    _playerNode = [self constructPlayerNode];
    
    if ([self.subnodes containsObject:_playButton]) {
      [self insertSubnode:_playerNode belowSubnode:_playButton];
    } else {
      [self addSubnode:_playerNode];
    }
  }
  
  [_player play];
  _shouldBePlaying = YES;
  
  [UIView animateWithDuration:0.15 animations:^{
    _playButton.alpha = 0.0;
  }];
  
  if (![self ready] && _shouldBePlaying && ASInterfaceStateIncludesVisible(self.interfaceState)) {
    [self addSubnode:_spinner];
    [(UIActivityIndicatorView *)_spinner.view startAnimating];
  }
}

- (BOOL)ready
{
  return _currentPlayerItem.status == AVPlayerItemStatusReadyToPlay;
}

- (void)pause
{
  ASDN::MutexLocker l(_videoLock);
  
  [_player pause];
  [((UIActivityIndicatorView *)_spinner.view) stopAnimating];
  _shouldBePlaying = NO;
  [UIView animateWithDuration:0.15 animations:^{
    _playButton.alpha = 1.0;
  }];
}

- (BOOL)isPlaying
{
  ASDN::MutexLocker l(_videoLock);
  
  return (_player.rate > 0 && !_player.error);
}

- (void)willResignActive:(NSNotification *)notification
{
  [self pause];
}


#pragma mark - Playback observers

- (void)didPlayToEnd:(NSNotification *)notification
{
  if ([_delegate respondsToSelector:@selector(videoPlaybackDidFinish:)]) {
    [_delegate videoPlaybackDidFinish:self];
  }
  [_player seekToTime:CMTimeMakeWithSeconds(0, 1)];
  
  if (_shouldAutorepeat) {
    [self play];
  } else {
    [self pause];
  }
}

- (void)errorWhilePlaying:(NSNotification *)notification
{
  if ([notification.name isEqualToString:AVPlayerItemFailedToPlayToEndTimeNotification]) {
    NSLog(@"Failed to play video");
  }
  else if ([notification.name isEqualToString:AVPlayerItemNewErrorLogEntryNotification]) {
    AVPlayerItem* item = (AVPlayerItem*)notification.object;
    AVPlayerItemErrorLogEvent* logEvent = item.errorLog.events.lastObject;
    NSLog(@"AVPlayerItem error log entry added for video with error %@ status %@", item.error,
          (item.status == AVPlayerItemStatusFailed ? @"FAILED" : [NSString stringWithFormat:@"%ld", (long)item.status]));
    NSLog(@"Item is %@", item);
    
    if (logEvent)
      NSLog(@"Log code %ld domain %@ comment %@", (long)logEvent.errorStatusCode, logEvent.errorDomain, logEvent.errorComment);
  }
}


#pragma mark - Property Accessors for Tests

- (ASDisplayNode *)spinner
{
  ASDN::MutexLocker l(_videoLock);
  return _spinner;
}

- (AVPlayerItem *)currentItem
{
  ASDN::MutexLocker l(_videoLock);
  return _currentPlayerItem;
}

- (void)setCurrentItem:(AVPlayerItem *)currentItem
{
  ASDN::MutexLocker l(_videoLock);
  _currentPlayerItem = currentItem;
}

- (ASDisplayNode *)playerNode
{
  ASDN::MutexLocker l(_videoLock);
  return _playerNode;
}

- (BOOL)shouldBePlaying
{
  ASDN::MutexLocker l(_videoLock);
  return _shouldBePlaying;
}

#pragma mark - Lifecycle

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
  
  if (_periodicTimeObserver) {
    [_player removeTimeObserver:_periodicTimeObserver];
    _periodicTimeObserver = nil;
  }
  
  [self removePlayerItemObservers];
  
  @try {
    [_currentPlayerItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(status))];
  }
  @catch (NSException * __unused exception) {
//    NSLog(@"unnecessary removal in dealloc");
  }
}

@end
