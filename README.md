# ToDoPlus

A to-do list for World of Warcraft, in a panel you can move, resize and style. Type `/todo` in game to show or hide it, and `/todo config` to open the settings.

## Features

### The list

- Checklist items, grouped under categories you can collapse. Items can also sit above the first category.
- Checking an item off greys it out and strikes it through.
- Hold the edit key (CTRL, SHIFT or ALT, chosen in settings) to edit:
  - a **+** row appears under the items to add another, and at the very end to add a category;
  - a red **X** appears after each item and category to remove it;
  - clicking an item or category renames it.
- In a text box, Enter saves and stays open for the next item, and Escape cancels.
- An account-wide list shared by all your characters, plus one list per character. Switch between them with the **A / C** button in the title bar.

### The panel

- Drag to move, and resize from either bottom corner. The padlock in the title bar locks the panel in place; the list can still be checked off and edited.
- Background and border textures (the game's own, plus anything registered with LibSharedMedia), with colors and border size.
- Fonts, sizes, outline and colors for the title, categories and items, and a color for completed items.

### Markdown

Addons can't write files, so lists are saved with your settings when you log out or `/reload`. To get a list out as Markdown, use **Export** on the List settings page (or `/todo export`) and copy it with Ctrl+C. **Import** (or `/todo import`) takes pasted Markdown and either adds it to the list or replaces it:

```markdown
# To-Do List
- [ ] an item above the first category

## Category
- [ ] an item
- [x] a done item
```

### Titan Panel

A launcher for Titan Panel and other LibDataBroker displays: click it to show or hide the list, and Shift-click to open settings. In Titan Panel, turn it on under **Interface → ToDoPlus**.

## Commands

| Command | |
| --- | --- |
| `/todo` | Show or hide the list |
| `/todo lock`, `/todo unlock` | Stop or allow moving and resizing |
| `/todo account`, `/todo character` | Switch lists |
| `/todo export`, `/todo import` | Copy the list as Markdown, or paste one in |
| `/todo config` | Open settings |
| `/todo reset` | Reset all settings (your lists are kept) |
