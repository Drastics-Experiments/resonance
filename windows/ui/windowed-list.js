// Keep the complete scroll range, but only build nearby items. Measured block
// heights survive eviction so wrapped titles retain their space in the list.
function navigationButton(label, show) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'sr-only';
  button.textContent = label;
  button.onfocus = () => queueMicrotask(() => {
    if (document.activeElement === button) show();
  });
  button.onclick = show;
  return button;
}

export function mountWindowedRows(container, {
  scroller, items, renderItem, bind, estimatedHeight, gap = 0, hold = () => false,
}) {
  const blockSize = 25;
  const blocks = [];
  const visible = new Set();
  const mounted = new Set();
  let disposed = false;
  const fill = (block) => {
    if (disposed || mounted.has(block)) return;
    const restoreFocus = block.contains(document.activeElement);
    const start = Number(block.dataset.start);
    block.style.height = '';
    block.innerHTML = items.slice(start, start + blockSize).map((item, index) => renderItem(item, start + index)).join('');
    mounted.add(block);
    bind(block);
    if (restoreFocus) block.querySelector('button, [tabindex="0"], a[href]')?.focus({ preventScroll: true });
  };
  const placeholder = (block) => {
    const start = Number(block.dataset.start);
    block.replaceChildren(navigationButton(`Show items ${start + 1} through ${Math.min(start + blockSize, items.length)} of ${items.length}`, () => {
      if (disposed) return;
      fill(block);
      const target = block.querySelector('button, [tabindex="0"], a[href]');
      target?.focus({ preventScroll: true });
      target?.scrollIntoView({ block: 'nearest', behavior: 'instant' });
    }));
  };
  const trim = () => {
    if (disposed || hold()) return;
    for (const block of mounted) {
      if (visible.has(block) || block.contains(document.activeElement)) continue;
      block.style.height = `${block.getBoundingClientRect().height}px`;
      placeholder(block);
      mounted.delete(block);
    }
  };
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) { visible.add(entry.target); fill(entry.target); }
      else visible.delete(entry.target);
    }
    trim();
  }, { root: scroller, rootMargin: '1000px 0px' });
  for (let start = 0; start < items.length; start += blockSize) {
    const block = document.createElement('div');
    block.dataset.start = String(start);
    const count = Math.min(blockSize, items.length - start);
    block.style.height = `${count * estimatedHeight + (count - 1) * gap}px`;
    block.style.display = 'grid';
    block.style.gap = `${gap}px`;
    block.style.position = 'relative';
    placeholder(block);
    blocks.push(block);
  }
  container.replaceChildren(...blocks);
  // Fill the initial viewport synchronously; observers handle restored scroll
  // positions and subsequent scrolling before they enter the visible area.
  const offset = scroller.getBoundingClientRect().top - container.getBoundingClientRect().top
    + (scroller === container ? scroller.scrollTop : 0);
  const firstBlock = Math.max(0, Math.floor(offset / (blockSize * (estimatedHeight + gap))) - 1);
  for (const block of blocks.slice(firstBlock, firstBlock + 3)) { visible.add(block); fill(block); }
  blocks.forEach((block) => observer.observe(block));
  const deferTrim = () => queueMicrotask(trim);
  container.addEventListener('focusout', deferTrim);
  container.addEventListener('pointerup', deferTrim);
  container.addEventListener('pointercancel', deferTrim);
  return () => {
    disposed = true;
    observer.disconnect();
    container.removeEventListener('focusout', deferTrim);
    container.removeEventListener('pointerup', deferTrim);
    container.removeEventListener('pointercancel', deferTrim);
  };
}

// Explicit grid-column positions preserve the existing six-card grid, gaps,
// and horizontal scroll extent without inserting thousands of image buttons.
export function mountWindowedCards(container, items, renderItem, bind) {
  const nodes = new Map();
  let disposed = false;
  let start = 0;
  let stop = 0;
  const reveal = (index) => {
    if (disposed) return;
    container.scrollLeft = index * (end.getBoundingClientRect().width + 18);
    update();
    nodes.get(index)?.focus();
  };
  const previous = navigationButton('Show previous items', () => reveal(Math.max(0, start - 1)));
  const next = navigationButton('Show next items', () => reveal(stop));
  const end = document.createElement('span');
  end.setAttribute('aria-hidden', 'true');
  end.style.gridColumn = String(items.length);
  container.append(previous, end, next);
  let frame = 0;
  const update = () => {
    frame = 0;
    if (disposed) return;
    const width = end.getBoundingClientRect().width;
    start = Math.max(0, Math.floor(container.scrollLeft / (width + 18)) - 6);
    stop = Math.min(items.length, start + Math.ceil(container.clientWidth / (width + 18)) + 13);
    previous.hidden = start === 0;
    next.hidden = stop === items.length;
    for (const [index, node] of nodes) {
      if ((index < start || index >= stop) && !node.contains(document.activeElement)) {
        node.remove(); nodes.delete(index);
      }
    }
    for (let index = start; index < stop; index += 1) {
      if (nodes.has(index)) continue;
      const template = document.createElement('template');
      template.innerHTML = renderItem(items[index]);
      const node = template.content.firstElementChild;
      node.style.gridColumn = String(index + 1);
      node.style.gridRow = '1';
      const next = [...nodes].filter(([other]) => other > index).sort(([a], [b]) => a - b)[0]?.[1] || end;
      container.insertBefore(node, next);
      nodes.set(index, node);
      bind(node);
    }
    end.style.gridRow = '1';
  };
  const schedule = () => { if (!frame) frame = requestAnimationFrame(update); };
  const resize = new ResizeObserver(schedule);
  container.addEventListener('scroll', schedule, { passive: true });
  container.addEventListener('focusout', schedule);
  resize.observe(container);
  update();
  return () => {
    disposed = true;
    cancelAnimationFrame(frame);
    resize.disconnect();
    container.removeEventListener('scroll', schedule);
    container.removeEventListener('focusout', schedule);
  };
}
