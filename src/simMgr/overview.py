"""Summary and GPC status panes sharing one page."""

import curses

from .gpcview import GpcView
from .screen import ScreenRegion
from .summary import SummaryView


class PaneApp:
    def __init__(self, overview):
        self.overview = overview

    def __getattr__(self, name):
        return getattr(self.overview.app, name)

    @property
    def screen(self):
        return self.overview.regions(self.overview.app.screen)[1] or self.overview.app.screen

    def page_bar(self, screen):
        pass

    def title_bar(self, screen, title):
        self.title = title

    def message_line(self, screen, row):
        pass

    def close_view(self):
        self.overview.close_detail()

    def close_detail(self):
        self.close_view()


class Overview:
    MIN_SUMMARY_WIDTH = 40
    GPC_WIDTH = 132

    def __init__(self, app):
        self.app = app
        self.summary = SummaryView(app)
        self.pane_app = PaneApp(self)
        self.gpc = GpcView(self.pane_app)
        self.pages = [("GPC STATUS", self.gpc)]
        self.page = 0
        self.details = []
        self.focus = 0

    def add_pages(self, pages):
        for name, view in pages:
            view.app = self.pane_app
            self.pages.append((name, view))

    @property
    def right_view(self):
        return self.details[-1][0] if self.details else self.pages[self.page][1]

    def open_detail(self, view):
        view.app = self.pane_app
        self.details.append((view, self.focus))
        self.focus = 1

    def close_detail(self):
        if self.details:
            view, self.focus = self.details.pop()
            close = getattr(view, "close", None)
            if close:
                close()

    def close(self):
        while self.details:
            self.close_detail()

    def regions(self, screen):
        columns, _, _, column_width, _ = self.summary.geometry(screen)
        available = screen.w - self.GPC_WIDTH - 1
        if available < max(self.MIN_SUMMARY_WIDTH, column_width):
            return [screen if index == self.focus else None for index in range(2)]
        left = min(available, max(self.MIN_SUMMARY_WIDTH, len(columns) * column_width))
        return [ScreenRegion(screen, 0, 0, screen.h, left),
                ScreenRegion(screen, 3, left + 1, screen.h - 3, screen.w - left - 1)]

    def draw(self, screen):
        self.app.title_bar(screen, self.app.sup.config.name)
        self.app.page_bar(screen)
        regions = self.regions(screen)
        split = all(region is not None for region in regions)
        if regions[0] is not None:
            self.summary.draw(regions[0], embedded=True, focused=self.focus == 0,
                              header_screen=screen if split else None)
        if regions[1] is not None:
            self.pane_app.title = ""
            view = self.right_view
            if isinstance(view, GpcView):
                view.draw(regions[1], focused=self.focus == 1)
            else:
                view.draw(regions[1])
        if split:
            for row in range(5, screen.h - 2):
                screen.put(row, regions[0].w, screen.g.vline, screen.attr("dim"))
            title = self.pane_app.title if self.details else self.pages[self.page][0]
            screen.put(1, regions[0].w + 2, title,
                       screen.attr("title", reverse=self.focus == 1))
        elif self.focus == 1:
            screen.fill(1)
            title = self.pane_app.title if self.details else self.pages[self.page][0]
            screen.put(1, 2, title, screen.attr("title"))
        self.app.message_line(screen, screen.h - 2)
        screen.fill(screen.h - 1)
        self.app.hint_line(screen, screen.h - 1,
                           "F6 next right view  F7 focus (%s)  esc back  arrows/tab select  enter act  q quit" %
                           ("summary" if self.focus == 0 else "right"))

    def handle(self, key):
        if key == curses.KEY_F6:
            self.close()
            self.page = (self.page + 1) % len(self.pages)
            self.focus = 1
        elif key == curses.KEY_F7:
            self.focus = 1 - self.focus
        elif key == 27 and self.details:
            self.close_detail()
        elif key == 27 and self.focus == 1:
            self.focus = 0
        elif self.focus == 0:
            self.summary.handle(key, self.regions(self.app.screen)[0])
        else:
            self.right_view.handle(key)

    def cursor_position(self, screen):
        return self.summary.cursor_position(self.regions(screen)[0] or screen)
