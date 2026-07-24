package main

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/mobai-app/simslim"
)

const (
	topRefresh = 2 * time.Second  // fleet/process memory refresh cadence
	diskTTL    = 30 * time.Second // disk usage is slow, so refresh it rarely
)

var (
	topHeaderStyle = lipgloss.NewStyle().Bold(true)
	topSelStyle    = lipgloss.NewStyle().Reverse(true)
	topFaintStyle  = lipgloss.NewStyle().Faint(true)
)

// runTopTUI launches the interactive fleet monitor. initialUDID, when set, opens
// straight into that simulator's per-daemon drill-down.
func runTopTUI(ctx context.Context, initialUDID, initialName string) error {
	m := topModel{ctx: ctx, disk: map[string]int64{}, sortCol: sortRAM, sortDesc: true}
	if initialUDID != "" {
		m.view = viewDrill
		m.selUDID = initialUDID
		m.selName = initialName
	}
	_, err := tea.NewProgram(m, tea.WithContext(ctx), tea.WithAltScreen()).Run()
	return err
}

type topView int

const (
	viewFleet topView = iota
	viewDrill
)

// sortCol selects the column both the fleet table and the drill-down sort on.
type sortCol int

const (
	sortRAM sortCol = iota
	sortCPU
	sortProc
	sortDisk
	sortName
	sortState
	sortOS
)

// sortKeys maps a keypress to the column it sorts by, in header order:
// name, os, state, proc, cpu, ram, disk. Vim-nav keys (h/j/k/l) are excluded.
var sortKeys = map[string]sortCol{
	"n": sortName, "o": sortOS, "s": sortState, "p": sortProc, "c": sortCPU, "m": sortRAM, "d": sortDisk,
}

type (
	tickMsg  time.Time
	fleetMsg struct {
		out simslim.TopOutput
		err error
	}
	diskMsg map[string]int64
	procMsg struct {
		udid  string
		procs []simslim.Process
		err   error
	}
)

type topModel struct {
	ctx           context.Context
	view          topView
	width, height int

	sims       []simslim.TopSim
	total      int64
	cursor     int
	cursorUDID string // the selected sim; keeps the cursor anchored across live re-sorts
	err        error
	loaded     bool // first fleet snapshot has arrived

	disk     map[string]int64
	diskAt   time.Time
	diskBusy bool // a du sweep is in flight; don't start another
	sortCol  sortCol
	sortDesc bool

	selUDID string
	selName string
	procs   []simslim.Process
	procErr error
	scroll  int
}

func (m topModel) Init() tea.Cmd {
	return tea.Batch(m.refreshFleet(), tickCmd(), m.refreshProcs())
}

func tickCmd() tea.Cmd {
	return tea.Tick(topRefresh, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m topModel) refreshFleet() tea.Cmd {
	ctx := m.ctx
	return func() tea.Msg {
		out, err := simslim.FleetSnapshot(ctx, false)
		return fleetMsg{out: out, err: err}
	}
}

// refreshDisk measures disk for the given udids (or the current fleet when nil).
func (m topModel) refreshDisk(udids []string) tea.Cmd {
	ctx := m.ctx
	if udids == nil {
		for _, s := range m.sims {
			udids = append(udids, s.UDID)
		}
	}
	return func() tea.Msg {
		out := diskMsg{}
		for _, u := range udids {
			if du, err := simslim.DeviceDiskUsage(ctx, u); err == nil {
				out[u] = du.Bytes
			}
		}
		return out
	}
}

func (m topModel) refreshProcs() tea.Cmd {
	if m.view != viewDrill || m.selUDID == "" {
		return nil
	}
	ctx, udid := m.ctx, m.selUDID
	return func() tea.Msg {
		procs, err := simslim.MeasureProcesses(ctx, udid)
		return procMsg{udid: udid, procs: procs, err: err}
	}
}

func (m topModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil

	case tickMsg:
		cmds := []tea.Cmd{tickCmd(), m.refreshFleet()}
		if c := m.refreshProcs(); c != nil {
			cmds = append(cmds, c)
		}
		if !m.diskBusy && !m.diskAt.IsZero() && time.Since(m.diskAt) > diskTTL {
			m.diskBusy = true
			cmds = append(cmds, m.refreshDisk(nil))
		}
		return m, tea.Batch(cmds...)

	case fleetMsg:
		m.err = msg.err
		if msg.err != nil {
			return m, nil // keep showing the previous snapshot; footer reports the error
		}
		m.loaded = true
		m.sims, m.total = msg.out.Sims, msg.out.TotalBytes
		m.applySort()
		m.reanchor()

		var missing []string
		for _, s := range m.sims {
			if _, ok := m.disk[s.UDID]; !ok {
				missing = append(missing, s.UDID)
			}
		}
		if len(missing) > 0 && !m.diskBusy {
			m.diskBusy = true
			return m, m.refreshDisk(missing)
		}
		return m, nil

	case diskMsg:
		m.diskBusy = false
		for u, b := range msg {
			m.disk[u] = b
		}
		m.diskAt = time.Now()
		if m.sortCol == sortDisk {
			m.applySort()
			m.reanchor()
		}
		return m, nil

	case procMsg:
		if msg.udid == m.selUDID {
			m.procs, m.procErr = msg.procs, msg.err
			m.sortProcs()
			if m.scroll >= len(m.procs) {
				m.scroll = max(0, len(m.procs)-1)
			}
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m topModel) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "up", "k":
		if m.view == viewFleet && m.cursor > 0 {
			m.cursor--
			m.cursorUDID = m.sims[m.cursor].UDID
		} else if m.view == viewDrill && m.scroll > 0 {
			m.scroll--
		}
	case "down", "j":
		if m.view == viewFleet && m.cursor < len(m.sims)-1 {
			m.cursor++
			m.cursorUDID = m.sims[m.cursor].UDID
		} else if m.view == viewDrill && m.scroll < len(m.procs)-1 {
			m.scroll++
		}
	case "enter", "right", "l":
		if m.view == viewFleet && m.cursor < len(m.sims) {
			s := m.sims[m.cursor]
			m.view, m.selUDID, m.selName = viewDrill, s.UDID, s.Name
			m.procs, m.procErr, m.scroll = nil, nil, 0
			return m, m.refreshProcs()
		}
	case "esc", "left", "h":
		if m.view == viewDrill {
			m.view, m.selUDID, m.procs = viewFleet, "", nil
		}
	default:
		if col, ok := sortKeys[msg.String()]; ok {
			if m.view == viewDrill && col != sortRAM && col != sortCPU && col != sortName {
				return m, nil
			}
			m.setSort(col)
		}
	}
	return m, nil
}

// reanchor points the cursor back at the selected sim after a re-sort or
// refresh reorders (or removes) rows.
func (m *topModel) reanchor() {
	if m.cursorUDID != "" {
		for i, s := range m.sims {
			if s.UDID == m.cursorUDID {
				m.cursor = i
				return
			}
		}
		m.cursorUDID = ""
	}
	if m.cursor >= len(m.sims) {
		m.cursor = max(0, len(m.sims)-1)
	}
}

// setSort switches the sort column, or flips direction when the column is
// already active, then re-sorts the current view.
func (m *topModel) setSort(col sortCol) {
	if m.sortCol == col {
		m.sortDesc = !m.sortDesc
	} else {
		m.sortCol, m.sortDesc = col, true
	}
	m.applySort()
	m.reanchor()
	m.sortProcs()
}

// applySort orders the fleet by the active column and direction.
func (m *topModel) applySort() {
	less := func(a, b simslim.TopSim) bool {
		switch m.sortCol {
		case sortCPU:
			return simCPU(a) < simCPU(b)
		case sortProc:
			return simProcs(a) < simProcs(b)
		case sortDisk:
			return m.disk[a.UDID] < m.disk[b.UDID]
		case sortName:
			return a.Name < b.Name
		case sortState:
			return simDisabled(a) < simDisabled(b)
		case sortOS:
			return osLess(a.OSVersion, b.OSVersion)
		default:
			return simBytes(a) < simBytes(b)
		}
	}
	sort.SliceStable(m.sims, func(i, j int) bool {
		if m.sortDesc {
			return less(m.sims[j], m.sims[i])
		}
		return less(m.sims[i], m.sims[j])
	})
}

// sortProcs orders the drill-down. Only RAM/CPU/name apply to processes; other
// columns fall back to RAM so a fleet sort choice still behaves sensibly here.
func (m *topModel) sortProcs() {
	less := func(a, b simslim.Process) bool {
		switch m.sortCol {
		case sortCPU:
			return a.CPU < b.CPU
		case sortName:
			return a.Command < b.Command
		default:
			return a.Bytes < b.Bytes
		}
	}
	sort.SliceStable(m.procs, func(i, j int) bool {
		if m.sortDesc {
			return less(m.procs[j], m.procs[i])
		}
		return less(m.procs[i], m.procs[j])
	})
}

func (m topModel) View() string {
	if m.view == viewDrill {
		return m.drillView()
	}
	return m.fleetView()
}

func (m topModel) fleetView() string {
	var b strings.Builder
	b.WriteString(topHeaderStyle.Render(m.fleetHeader()))
	b.WriteByte('\n')

	if m.err != nil && !m.loaded {
		b.WriteString(topFaintStyle.Render(m.err.Error()))
		return b.String()
	}
	if !m.loaded {
		b.WriteString(topFaintStyle.Render("Loading booted simulators…"))
		b.WriteByte('\n')
		return b.String()
	}
	if len(m.sims) == 0 {
		b.WriteString(topFaintStyle.Render("No booted simulators. Boot one with `simslim boot <udid>`."))
		b.WriteByte('\n')
		return b.String() + m.footer()
	}

	nw := m.nameWidth()
	for i, s := range m.sims {
		row := fmt.Sprintf("%-*s %-6s %-6s %5s %6s %8s %8s",
			nw, truncate(fmt.Sprintf("%s · %s", s.Name, shortUDID(s.UDID)), nw),
			osLabel(s), stateLabel(s), procCount(s), cpuLabel(s), ramLabel(s), diskLabel(m.disk, s.UDID))
		if i == m.cursor {
			b.WriteString(topSelStyle.Render(row))
		} else {
			b.WriteString(row)
		}
		b.WriteByte('\n')
	}
	return b.String() + m.footer()
}

// sortArrow returns the direction indicator when col is the active sort column.
func (m topModel) sortArrow(col sortCol) string {
	if m.sortCol != col {
		return ""
	}
	if m.sortDesc {
		return "▼"
	}
	return "▲"
}

func (m topModel) fleetHeader() string {
	return fmt.Sprintf("%-*s %-6s %-6s %5s %6s %8s %8s",
		m.nameWidth(), "SIMULATOR"+m.sortArrow(sortName), "OS"+m.sortArrow(sortOS), "STATE"+m.sortArrow(sortState),
		"PROC"+m.sortArrow(sortProc), "CPU"+m.sortArrow(sortCPU), "RAM"+m.sortArrow(sortRAM), "DISK"+m.sortArrow(sortDisk))
}

// fleetFixedCols is every non-name column plus the single spaces between all
// seven columns: OS(6)+STATE(6)+PROC(5)+CPU(6)+RAM(8)+DISK(8) + 6 separators.
const fleetFixedCols = 45

// nameWidth flexes the SIMULATOR column to fill the terminal: it grows when
// there is room and shrinks (down to a floor) when there is not.
func (m topModel) nameWidth() int {
	if m.width <= 0 {
		return 30 // no WindowSizeMsg yet
	}
	switch w := m.width - fleetFixedCols; {
	case w < 16:
		return 16
	case w > 60:
		return 60
	default:
		return w
	}
}

func (m topModel) tableWidth() int { return m.nameWidth() + fleetFixedCols }

func (m topModel) footer() string {
	summary := fmt.Sprintf("%d booted · total %s", len(m.sims), fmtBytes(m.total))
	hint := "↑↓ select · ↵ open · sort n·o·s·p·c·m·d · q quit"
	s := strings.Repeat("─", m.tableWidth()) + "\n" + summary + " · " + hint
	if m.err != nil {
		s += "\nrefresh error: " + m.err.Error()
	}
	return topFaintStyle.Render(s)
}

func (m topModel) drillView() string {
	var b strings.Builder
	title := m.selName
	if title == "" {
		title = shortUDID(m.selUDID)
	}
	b.WriteString(topHeaderStyle.Render(fmt.Sprintf("%s — daemons by %s", title, m.drillSortLabel())))
	b.WriteString("\n\n")

	if m.procErr != nil {
		b.WriteString(topFaintStyle.Render(m.procErr.Error()))
		b.WriteString("\n\n")
		b.WriteString(topFaintStyle.Render("esc back · q quit"))
		return b.String()
	}
	if len(m.procs) == 0 {
		b.WriteString(topFaintStyle.Render("measuring…"))
		b.WriteString("\n\n")
		b.WriteString(topFaintStyle.Render("esc back · q quit"))
		return b.String()
	}

	b.WriteString(topHeaderStyle.Render(fmt.Sprintf("%8s %6s  %s",
		"RAM"+m.sortArrow(sortRAM), "CPU"+m.sortArrow(sortCPU), "COMMAND"+m.sortArrow(sortName))))
	b.WriteByte('\n')

	rows := max(1, m.visibleRows())
	start := clampScroll(m.scroll, len(m.procs), rows)
	end := min(len(m.procs), start+rows)
	for _, p := range m.procs[start:end] {
		b.WriteString(fmt.Sprintf("%8s %5.1f%%  %s\n", fmtBytes(p.Bytes), p.CPU, p.Command))
	}

	pos := fmt.Sprintf("%d–%d of %d", start+1, end, len(m.procs))
	b.WriteString(topFaintStyle.Render(fmt.Sprintf("%s · ↑↓ scroll · sort m·c·n · esc back · q quit", pos)))
	return b.String()
}

// drillSortLabel names the drill-down's effective sort column (fleet-only
// columns fall back to RAM there, see sortProcs).
func (m topModel) drillSortLabel() string {
	switch m.sortCol {
	case sortCPU:
		return "CPU"
	case sortName:
		return "command"
	default:
		return "RAM"
	}
}

// visibleRows is the process-list height: total minus title, blank, header, footer.
func (m topModel) visibleRows() int {
	if m.height == 0 {
		return 20
	}
	return m.height - 5
}

// --- sort value helpers (absent memory/status sorts last under descending) ---

func simBytes(s simslim.TopSim) int64 {
	if s.Memory == nil {
		return -1
	}
	return s.Memory.Bytes
}

func simCPU(s simslim.TopSim) float64 {
	if s.Memory == nil {
		return -1
	}
	return s.Memory.CPU
}

func simProcs(s simslim.TopSim) int {
	if s.Memory == nil {
		return -1
	}
	return s.Memory.Processes
}

func simDisabled(s simslim.TopSim) int {
	if s.ManagedDisabled == nil {
		return -1
	}
	return *s.ManagedDisabled
}

// osLess compares dotted version strings numerically ("9.0" < "26.4", which
// lexical order gets wrong). Non-numeric segments compare lexically; a missing
// version sorts first.
func osLess(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) && i < len(bs); i++ {
		ai, aerr := strconv.Atoi(as[i])
		bi, berr := strconv.Atoi(bs[i])
		if aerr == nil && berr == nil {
			if ai != bi {
				return ai < bi
			}
			continue
		}
		if as[i] != bs[i] {
			return as[i] < bs[i]
		}
	}
	return len(as) < len(bs)
}

// --- formatting helpers ---

func stateLabel(s simslim.TopSim) string {
	if s.StatusError != "" || s.ManagedDisabled == nil {
		return "?"
	}
	switch {
	case *s.ManagedDisabled == s.ManagedTotal:
		return "slim"
	case *s.ManagedDisabled > 0:
		return "part"
	default:
		return "stock"
	}
}

func osLabel(s simslim.TopSim) string {
	if s.OSVersion == "" {
		return "?"
	}
	return truncate(s.OSVersion, 6)
}

func procCount(s simslim.TopSim) string {
	if s.Memory == nil {
		return "—"
	}
	return fmt.Sprintf("%d", s.Memory.Processes)
}

func cpuLabel(s simslim.TopSim) string {
	if s.Memory == nil {
		return "—"
	}
	return fmt.Sprintf("%.0f%%", s.Memory.CPU)
}

func ramLabel(s simslim.TopSim) string {
	if s.Memory == nil {
		if s.MemoryError != "" {
			return "err"
		}
		return "—"
	}
	return fmtBytes(s.Memory.Bytes)
}

func diskLabel(disk map[string]int64, udid string) string {
	if b, ok := disk[udid]; ok {
		return fmtBytes(b)
	}
	return "…"
}

func fmtBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%dB", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%c", float64(b)/float64(div), "KMGTPE"[exp])
}

func shortUDID(u string) string {
	if len(u) > 8 {
		return u[:8]
	}
	return u
}

func clampScroll(scroll, total, rows int) int {
	if scroll < 0 {
		return 0
	}
	if scroll > total-rows {
		return max(0, total-rows)
	}
	return scroll
}

// --- static (non-TTY) renderers, reused by cmdTop when stdout is piped ---

func staticFleet(out simslim.TopOutput) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%-30s %-6s %-6s %5s %6s %8s\n", "SIMULATOR", "OS", "STATE", "PROC", "CPU", "RAM")
	for _, s := range out.Sims {
		fmt.Fprintf(&b, "%-30s %-6s %-6s %5s %6s %8s\n",
			truncate(fmt.Sprintf("%s · %s", s.Name, shortUDID(s.UDID)), 30),
			osLabel(s), stateLabel(s), procCount(s), cpuLabel(s), ramLabel(s))
	}
	fmt.Fprintf(&b, "%d booted · total %s\n", len(out.Sims), fmtBytes(out.TotalBytes))
	return b.String()
}

func staticProcs(tp simslim.TopProcesses) string {
	var b strings.Builder
	name := tp.Name
	if name == "" {
		name = shortUDID(tp.UDID)
	}
	fmt.Fprintf(&b, "%s — daemons by RAM\n%8s %6s  %s\n", name, "RAM", "CPU", "COMMAND")
	for _, p := range tp.Processes {
		fmt.Fprintf(&b, "%8s %5.1f%%  %s\n", fmtBytes(p.Bytes), p.CPU, p.Command)
	}
	return b.String()
}
