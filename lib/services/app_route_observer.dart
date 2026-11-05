/// 全局路由观察者：用于「页面被别的路由盖住时暂停播放/动画」这类逻辑。
///
/// 用法：
/// - `main.dart` 里 `MaterialApp(navigatorObservers: [appRouteObserver])`
/// - 需要感知的 State 混入 `RouteAware`，在 `didChangeDependencies` 里
///   `appRouteObserver.subscribe(this, ModalRoute.of(context)!)`，
///   在 `dispose` 里 `unsubscribe`。
library;

import 'package:flutter/material.dart';

final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
