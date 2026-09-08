// 只沿可见编辑器/主内容的已提交 React 祖先寻找路由；不扫描缓存标签页。
(() => {
  const unavailable = () => JSON.stringify({routeKind: 'unavailable', conversationID: null});
  const visible = element => {
    if (!element.isConnected || !element.getClientRects().length) return false;
    for (let node = element; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (node.hidden || node.getAttribute('aria-hidden') === 'true' ||
          node.hasAttribute('inert') || style.display === 'none' || style.visibility === 'hidden') return false;
    }
    return true;
  };
  const routesFor = element => {
    // 富文本编辑器的内部 DOM 由编辑器库创建，React fiber 挂在外层宿主上。
    let fiber;
    for (let node = element, count = 0; node && count < 30; node = node.parentElement, count++) {
      const key = Object.keys(node).find(key => key.startsWith('__reactFiber$'));
      if (key) { fiber = node[key]; break; }
    }
    // DOM 可能仍持有上一次提交的 fiber，切换到当前树的 alternate。
    let top = fiber;
    const ancestors = new Set();
    while (top?.return && ancestors.size < 512 && !ancestors.has(top)) {
      ancestors.add(top);
      top = top.return;
    }
    if (top?.return) return [];
    if (top && top.stateNode?.current && top.stateNode.current !== top) fiber = fiber.alternate;
    const seen = new Set();
    let activeRoutes = null;
    let serviceTier;
    let inspected = 0;
    for (let count = 0; fiber && count < 512; count++, fiber = fiber.return) {
      const found = [];
      const tiers = new Set();
      const scan = (value, depth) => {
        if (!value || typeof value !== 'object' || depth > 5 || seen.has(value) || inspected++ > 12000) return;
        seen.add(value);
        if (Object.hasOwn(value, 'serviceTierForRequest') &&
            Object.hasOwn(value, 'selectedServiceTier') && Array.isArray(value.availableOptions) &&
            value.isLoading === false) {
          const tier = value.serviceTierForRequest;
          if (tier === null || typeof tier === 'string') tiers.add(tier ?? 'default');
          return;
        }
        if (typeof value.routeKind === 'string'  && typeof value.pathname === 'string') {
          found.push({routeKind: value.routeKind, conversationID: value.conversationId ?? null,
            hostID: value.hostId ?? 'local'});
          return;
        }
        // 只读取数据属性，避免调用 getter 或遍历 React 子树。
        // Compiler 的一个缓存行可能超过 100 个槽；逐个取数据属性，避免一次展开整棵对象。
        for (const key of Object.keys(value).slice(0, Array.isArray(value) ? 2048 : 100)) {
          if (/^(children|return|child|sibling|stateNode|alternate|_owner)$/.test(key)) continue;
          const descriptor = Object.getOwnPropertyDescriptor(value, key);
          if (descriptor && 'value' in descriptor) scan(descriptor.value, depth + 1);
        }
      };
      // 先读编译器缓存，每个 hook 的缓存行单独起算深度。
      const cache = fiber.updateQueue?.memoCache?.data;
      if (Array.isArray(cache)) for (const row of cache.slice(0, 512)) scan(row, 0);
      scan(fiber.memoizedProps, 0);
      // Hook 是链表；不能让通用对象扫描的深度限制截掉第六个以后的 hook。
      const hooks = new Set();
      for (let hook = fiber.memoizedState; hook && hooks.size < 256 && !hooks.has(hook); hook = hook.next) {
        hooks.add(hook);
        scan(hook.memoizedState ?? hook, 0);
      }
      const dependencies = new Set();
      for (let dependency = fiber.dependencies?.firstContext;
           dependency && dependencies.size < 200 && !dependencies.has(dependency); dependency = dependency.next) {
        dependencies.add(dependency);
        scan(dependency.memoizedValue, 0);
      }
      if (!activeRoutes && found.length) activeRoutes = found;
      if (serviceTier === undefined && tiers.size === 1) serviceTier = tiers.values().next().value;
      if (activeRoutes && serviceTier !== undefined) break;
    }
    return (activeRoutes ?? []).map(route => ({...route,
      serviceTierKnown: serviceTier !== undefined, serviceTier: serviceTier ?? null}));
  };
  // 多个同时可见的会话无法唯一确定时，拒绝猜测目标。
  for (const selector of ['[contenteditable="true"]', 'main, [role="main"]']) {
    const candidates = [...document.querySelectorAll(selector)].filter(visible).flatMap(routesFor);
    const unique = new Map();
    for (const candidate of candidates) {
      const key = JSON.stringify([candidate.routeKind, candidate.conversationID, candidate.hostID]);
      if (!unique.has(key)) unique.set(key, {...candidate, tiers: new Set()});
      if (candidate.serviceTierKnown) unique.get(key).tiers.add(candidate.serviceTier);
    }
    if (unique.size > 1) return unavailable();
    if (unique.size === 1) {
      const route = unique.values().next().value;
      if (route.hostID !== 'local') return unavailable();
      route.serviceTierKnown = route.tiers.size === 1;
      route.serviceTier = route.serviceTierKnown ? route.tiers.values().next().value : null;
      const conflictingTiers = route.tiers.size > 1;
      delete route.tiers;
      if (!route.serviceTierKnown && !conflictingTiers) {
        // 速度选择器与输入编辑器可能是兄弟组件，读取同一可见 composer 内的工具栏。
        const tiers = new Set();
        const editors = [...document.querySelectorAll('[contenteditable="true"]')].filter(visible);
        const composers = new Set(editors.map(e => e.closest('[class*="_ComposerLayoutRoot_"]')).filter(Boolean));
        for (const composer of composers) {
          for (const button of [...composer.querySelectorAll('button')].filter(visible).slice(0, 24)) {
            for (const candidate of routesFor(button)) {
              if (candidate.conversationID === route.conversationID && candidate.routeKind === route.routeKind &&
                  candidate.hostID === route.hostID && candidate.serviceTierKnown) tiers.add(candidate.serviceTier);
            }
          }
        }
        if (tiers.size === 1) { route.serviceTierKnown = true; route.serviceTier = tiers.values().next().value; }
      }
      return JSON.stringify(route);
    }
  }
  return unavailable();
})()
