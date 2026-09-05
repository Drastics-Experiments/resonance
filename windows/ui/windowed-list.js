// Keep the complete scroll range, but only build nearby items. Measured block
// heights survive eviction so wrapped titles retain their space in the list.
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
    const start = Number(block.dataset.start);
    block.style.height = '';
    block.innerHTML = items.slice(start, start + blockSize).map((item, index) => renderItem(item, start + index)).join('');
    mounted.add(block);
    bind(block);
  };
  const trim = () => {
    if (disposed || hold()) return;
    for (const block of mounted) {
      if (visible.has(block) || block.contains(document.activeElement)) continue;
      block.style.height = `${block.getBoundingClientRect().height}px`;
      block.replaceChildren();
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
  const end = document.createElement('span');
  end.setAttribute('aria-hidden', 'true');
  end.style.gridColumn = String(items.length);
  container.append(end);
  let frame = 0;
  const update = () => {
    frame = 0;
    const width = end.getBoundingClientRect().width;
    const start = Math.max(0, Math.floor(container.scrollLeft / (width + 18)) - 6);
    const stop = Math.min(items.length, start + Math.ceil(container.clientWidth / (width + 18)) + 13);
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
    cancelAnimationFrame(frame);
    resize.disconnect();
    container.removeEventListener('scroll', schedule);
    container.removeEventListener('focusout', schedule);
  };
}
