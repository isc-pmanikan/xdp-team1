/// One Boston 311 service request.
///
/// This class is simultaneously:
///   - the object model  (##class(ProjA.ServiceRequest).%OpenId(1))
///   - the SQL table      (SELECT * FROM ProjA.ServiceRequest)
/// Both read the same stored data. Use objects for single-record work,
/// SQL for the set operations (rankings, aggregates, top-N).
///
/// Note: elapsed-time metrics are deliberately NOT stored as properties.
/// "Hours open" is a function of the current time, so a persisted value
/// would be stale the moment it was written. It is computed at query time.
Class ProjA.ServiceRequest Extends %Persistent
{

/// Boston's own case number. Natural key from the source file.
Property CaseEnquiryId As %Integer;

Property OpenedDate As %TimeStamp;

/// Service-level-agreement deadline. Empty for ~12% of rows, which have no SLA.
Property SlaTargetDate As %TimeStamp;

/// Empty while the case is still open.
Property ClosedDate As %TimeStamp;

/// Boston's own ONTIME / OVERDUE flag, as-loaded. Kept for comparison, but
/// prefer HoursOverdue() below, which is computed live against the SLA.
Property OnTime As %String(MAXLEN = 10);

Property CaseStatus As %String(MAXLEN = 20);

/// Free text a case worker types, so its length is a property of the author
/// rather than of the data. 1000 was a guess and three rows in this extract
/// blew past it (max 1357). 4000 is not a better guess -- it is just headroom;
/// the loader clips to it so an unusually chatty note can never cost a whole
/// row again.
Property ClosureReason As %String(MAXLEN = 4000);

Property CaseTitle As %String(MAXLEN = 250);

Property Subject As %String(MAXLEN = 100);

Property Reason As %String(MAXLEN = 100);

/// Named RequestType, not Type, to stay clear of SQL reserved words.
Property RequestType As %String(MAXLEN = 100);

Property Queue As %String(MAXLEN = 100);

Property Department As %String(MAXLEN = 50);

Property SubmittedPhoto As %String(MAXLEN = 500);

Property ClosedPhoto As %String(MAXLEN = 500);

Property Location As %String(MAXLEN = 300);

Property FireDistrict As %String(MAXLEN = 10);

Property PwdDistrict As %String(MAXLEN = 10);

Property CityCouncilDistrict As %String(MAXLEN = 10);

Property PoliceDistrict As %String(MAXLEN = 10);

Property Neighborhood As %String(MAXLEN = 100);

Property NeighborhoodServicesDistrict As %String(MAXLEN = 10);

/// Normalized on load: source mixes "Ward 1" and "3", stored here as "1" / "3".
Property Ward As %String(MAXLEN = 10);

Property Precinct As %String(MAXLEN = 10);

Property StreetName As %String(MAXLEN = 200);

/// %String, not %Integer: the source has already lost the leading zero
/// ("2128"), and Boston zips need it back ("02128").
Property Zipcode As %String(MAXLEN = 5);

Property Latitude As %Double;

Property Longitude As %Double;

Property Source As %String(MAXLEN = 100);

Index CaseIdx On CaseEnquiryId [ Unique ];

Index StatusIdx On CaseStatus [ Type = bitmap ];

Index OnTimeIdx On OnTime [ Type = bitmap ];

Index DepartmentIdx On Department [ Type = bitmap ];

Index NeighborhoodIdx On Neighborhood [ Type = bitmap ];

Index OpenedIdx On OpenedDate;

Index SlaIdx On SlaTargetDate;

/// Fallback for the as-of instant, used until a load has derived one.
///
/// The spec says: "For date-based analysis, you may treat August 14, 2026 as the
/// current date." Reading the wall clock instead made the numbers drift. Two
/// concrete symptoms: the past-SLA count moved between two queries run a minute
/// apart, because cases cross their deadline while you watch; and by the time the
/// extract was four days old, 437 more cases had gone overdue than the data
/// itself can account for, so the dashboard disagreed with the source ON_TIME
/// flag purely because of the calendar. Pinned, the same question gives the same
/// answer today, at the demo, and next month.
///
/// Midnight rather than end-of-day: a deadline falling ON August 14 has not been
/// missed at the moment that day begins. 351 cases have a target that day, so the
/// choice is worth stating rather than leaving to whoever reads the SQL.
///
/// RefreshAsOf() derives this same value from the Base extract unaided -- the
/// latest activity there is 2026-08-13 22:30 and the midnight after it is
/// 2026-08-14 00:00 -- so the derived rule and the spec's date agree, and this
/// literal only serves an empty table.
Parameter ASOF = "2026-08-14 00:00:00";

/// The instant every "now" in this class is measured against.
///
/// Derived from the data, not from the wall clock and not frozen at a literal:
/// the midnight following the most recent thing that actually happened. A loader
/// calls RefreshAsOf() to recompute it, so arriving data moves the application's
/// notion of "now" with it. Without that, merging the Day 2 batch -- whose
/// activity runs to 2026-08-14 22:22 -- would leave 50 new cases with a negative
/// age and 30 closures dated in the future.
ClassMethod AsOfStamp() As %String [ CodeMode = expression ]
{
$Get(^ProjA.AsOf, ..#ASOF)
}

/// Recomputes and stores the as-of instant. Returns the value now in force.
///
/// "Latest activity" is the newest OpenedDate or ClosedDate; SlaTargetDate is
/// excluded because a deadline is by nature in the future (this extract has one
/// in 2028), and a promise about tomorrow is not evidence about today. The result
/// is rounded UP to the next midnight so that a full day of activity is always
/// in the past: with the instant sitting mid-afternoon instead, cases opened
/// later the same day would read as not yet having happened.
///
/// The greater-of comparison is done in SQL rather than ObjectScript on purpose.
/// ObjectScript's < and > coerce their operands to numbers, so comparing two
/// %TimeStamp strings there silently reduces both to 2026 and reports them equal.
ClassMethod RefreshAsOf() As %String
{
	Set latest = ..Sql1(
		"SELECT MAX(CASE WHEN ClosedDate IS NULL OR ClosedDate < OpenedDate "_
		"            THEN OpenedDate ELSE ClosedDate END) "_
		"FROM ProjA.ServiceRequest WHERE OpenedDate IS NOT NULL")
	// An empty table says nothing about the date; leave the fallback in place.
	If $Length(latest) < 10 Quit ..AsOfStamp()
	Set ^ProjA.AsOf = $ZDate($ZDateH($Extract(latest, 1, 10), 3) + 1, 3)_" 00:00:00"
	Quit ^ProjA.AsOf
}

/// The as-of instant as a SQL literal, for interpolation into the queries below.
///
/// A quoted string rather than TIMESTAMP'...': %TimeStamp columns compare and
/// DATEDIFF against a plain string literal on every version this ran on, and the
/// literal keeps the value visible in the query text when a statement is dumped.
ClassMethod AsOf() As %String [ CodeMode = expression ]
{
"'"_..AsOfStamp()_"'"
}

/// Whole hours between two %TimeStamp values, via $Horolog arithmetic so it
/// works on every IRIS version (the SQL DATEDIFF class API moved around).
ClassMethod HoursBetween(fromStamp As %TimeStamp, toStamp As %TimeStamp) As %Integer
{
	If (fromStamp = "") || (toStamp = "") Quit ""
	Set from = $ZDateTimeH(fromStamp, 3)
	Set to = $ZDateTimeH(toStamp, 3)
	Set seconds = (($Piece(to, ",", 1) - $Piece(from, ",", 1)) * 86400)
		+ ($Piece(to, ",", 2) - $Piece(from, ",", 2))
	Quit seconds \ 3600
}

/// Hours this case has been open: to closure if closed, to now if still open.
Method HoursOpen() As %Integer
{
	Set endPoint = $Select(..ClosedDate '= "": ..ClosedDate, 1: ..AsOfStamp())
	Quit ..HoursBetween(..OpenedDate, endPoint)
}

/// Positive = past its SLA deadline by this many hours. Empty when no SLA.
Method HoursOverdue() As %Integer
{
	If ..SlaTargetDate = "" Quit ""
	Set endPoint = $Select(..ClosedDate '= "": ..ClosedDate, 1: ..AsOfStamp())
	Quit ..HoursBetween(..SlaTargetDate, endPoint)
}

/// True when this case is in the attention queue as things stand: still open, it
/// has a deadline, and that deadline has passed.
///
/// The same rule AttentionQueueData() applies in SQL, expressed against a single
/// object. Both exist deliberately -- SQL for the set operation, this for asking
/// about one case without a round trip, which is what the Day 2 merge needs in
/// order to say which cases entered or left the queue.
///
/// ]] (follows) rather than <, because ObjectScript's relational operators are
/// numeric: "2026-08-13 22:30:00" < "2026-08-14 00:00:00" coerces both sides to
/// 2026 and answers false. These stamps are fixed-width YYYY-MM-DD HH:MM:SS, so
/// their lexical order is their chronological order.
Method InAttentionQueue() As %Boolean
{
	If ..CaseStatus '= "Open" Quit 0
	If ..SlaTargetDate = "" Quit 0
	Quit (..AsOfStamp() ]] ..SlaTargetDate)
}

/// Rows in the attention queue right now.
ClassMethod AttentionQueueCount() As %Integer
{
	Quit +..Sql1(
		"SELECT COUNT(*) FROM ProjA.ServiceRequest "_
		"WHERE CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL "_
		"  AND SlaTargetDate < "_..AsOf())
}

/// The handful of numbers a data load can move, for a before-and-after read.
///
/// Kept here rather than in the loader because these are statements about the
/// data; how they are laid out on a terminal is the loader's business.
ClassMethod StateSnapshot(Output snap) As %Status
{
	Kill snap
	Set snap("asOf") = ..AsOfStamp()
	Set snap("total") = +..Sql1("SELECT COUNT(*) FROM ProjA.ServiceRequest")
	Set snap("open") = +..Sql1(
		"SELECT COUNT(*) FROM ProjA.ServiceRequest WHERE CaseStatus = 'Open'")
	Set snap("closed") = +..Sql1(
		"SELECT COUNT(*) FROM ProjA.ServiceRequest WHERE CaseStatus = 'Closed'")
	Set snap("queue") = ..AttentionQueueCount()
	Quit $$$OK
}

/// Runs a query and prints it with column headers.
ClassMethod PrintQuery(sql As %String, args...) As %Status
{
	Set statement = ##class(%SQL.Statement).%New()
	Set sc = statement.%Prepare(sql)
	// Report the prepare failure. Returning it silently is worse than useless
	// here: Report() calls these with Do, which discards the status, so a query
	// that will not even compile produced no output and no error at all.
	If $$$ISERR(sc) {
		Write "SQL prepare failed: ", $System.Status.GetErrorText(sc), !
		Quit sc
	}
	Set resultSet = statement.%Execute(args...)
	If resultSet.%SQLCODE < 0 {
		Write "SQL error ", resultSet.%SQLCODE, ": ", resultSet.%Message, !
		Quit $$$ERROR($$$GeneralError, resultSet.%Message)
	}
	Do resultSet.%Display()
	Quit $$$OK
}

// ---------------------------------------------------------------
//  Analytics. All set operations, so all SQL.
// ---------------------------------------------------------------

/// MOST URGENT: still-open cases that have blown past their SLA, worst first.
ClassMethod MostUrgent(top As %Integer = 20) As %Status
{
	Quit ..PrintQuery(
		"SELECT TOP ? CaseEnquiryId, CaseTitle, Department, Neighborhood, "_
		"       OpenedDate, SlaTargetDate, "_
		"       DATEDIFF(hh, SlaTargetDate, "_..AsOf()_") AS HoursOverdue "_
		"FROM ProjA.ServiceRequest "_
		"WHERE CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL "_
		"  AND SlaTargetDate < "_..AsOf()_" "_
		"ORDER BY SlaTargetDate ASC", top)
}

/// MOST TIME UNFULFILLED: still-open cases by age, oldest first.
ClassMethod LongestUnfulfilled(top As %Integer = 20) As %Status
{
	Quit ..PrintQuery(
		"SELECT TOP ? CaseEnquiryId, CaseTitle, Department, Neighborhood, OpenedDate, "_
		"       DATEDIFF(dd, OpenedDate, "_..AsOf()_") AS DaysOpen "_
		"FROM ProjA.ServiceRequest "_
		"WHERE CaseStatus = 'Open' "_
		"ORDER BY OpenedDate ASC", top)
}

/// Which departments are worst at hitting their SLA?
///
/// This report and ByNeighborhood() below read Boston's own ON_TIME flag. The
/// dashboard does NOT: it compares SlaTargetDate to ..#ASOF. The two answer
/// different questions, and the difference is exact, not approximate:
///
///   flag OVERDUE  12,654 = 11,796 open and past SLA  +  858 that CLOSED late
///   flag ONTIME   12,346 =  7,974 closed on time
///                          + 900 open and still inside their deadline
///                          + 3,035 with NO SLA target at all
///
/// So the flag is a verdict on the case's whole life (did it miss its deadline,
/// ever), while the dashboard's "past SLA, still open" is a work queue (is
/// someone late RIGHT NOW). 11,796 appears in both columns because the as-of date
/// is pinned to the extract's own reference date -- against the wall clock the
/// live figure had drifted 437 cases higher, which is what made these two look
/// inconsistent when they were not.
///
/// Note also that the flag calls a case with no deadline ONTIME. This app
/// excludes those instead: "on time" against no target is not a fact about
/// service, it is a fact about missing data.
ClassMethod SlaByDepartment() As %Status
{
	Quit ..PrintQuery(
		"SELECT Department, "_
		"       COUNT(*) AS Total, "_
		"       SUM(CASE WHEN OnTime = 'OVERDUE' THEN 1 ELSE 0 END) AS Overdue, "_
		"       ROUND(100.0 * SUM(CASE WHEN OnTime = 'OVERDUE' THEN 1 ELSE 0 END) "_
		"             / COUNT(*), 1) AS PctOverdue "_
		"FROM ProjA.ServiceRequest "_
		"GROUP BY Department "_
		"ORDER BY PctOverdue DESC")
}

/// Highest-volume complaint types, with how long each takes to resolve.
ClassMethod TopRequestTypes(top As %Integer = 20) As %Status
{
	Quit ..PrintQuery(
		"SELECT TOP ? Reason, RequestType, COUNT(*) AS Total, "_
		"       AVG(DATEDIFF(hh, OpenedDate, ClosedDate)) AS AvgHoursToClose "_
		"FROM ProjA.ServiceRequest "_
		"GROUP BY Reason, RequestType "_
		"ORDER BY Total DESC", top)
}

/// Open backlog and overdue rate per neighborhood.
/// Overdue here is the source ON_TIME flag -- see SlaByDepartment() for exactly
/// how that differs from the dashboard's live comparison.
ClassMethod ByNeighborhood(top As %Integer = 25) As %Status
{
	Quit ..PrintQuery(
		"SELECT TOP ? Neighborhood, COUNT(*) AS Total, "_
		"       SUM(CASE WHEN CaseStatus = 'Open' THEN 1 ELSE 0 END) AS StillOpen, "_
		"       SUM(CASE WHEN OnTime = 'OVERDUE' THEN 1 ELSE 0 END) AS Overdue "_
		"FROM ProjA.ServiceRequest "_
		"GROUP BY Neighborhood "_
		"ORDER BY StillOpen DESC", top)
}

/// One-line health check of the loaded data.
///
/// The aliases avoid ROWS, OPEN, and CLOSED, which are IRIS SQL reserved words --
/// "COUNT(*) AS Rows" fails to prepare with SQLCODE -1. Same reason RequestType
/// is not called Type.
ClassMethod Summary() As %Status
{
	Quit ..PrintQuery(
		"SELECT COUNT(*) AS TotalRows, "_
		"       SUM(CASE WHEN CaseStatus = 'Open' THEN 1 ELSE 0 END) AS OpenCount, "_
		"       SUM(CASE WHEN CaseStatus = 'Closed' THEN 1 ELSE 0 END) AS ClosedCount, "_
		"       SUM(CASE WHEN OnTime = 'OVERDUE' THEN 1 ELSE 0 END) AS Overdue, "_
		"       SUM(CASE WHEN SlaTargetDate IS NULL THEN 1 ELSE 0 END) AS NoSla, "_
		"       MIN(OpenedDate) AS Earliest, MAX(OpenedDate) AS Latest "_
		"FROM ProjA.ServiceRequest")
}

/// Runs every report in sequence.
ClassMethod Report() As %Status
{
	Write !, "=== SUMMARY ===", ! Do ..Summary()
	Write !, "=== MOST URGENT (open + past SLA) ===", ! Do ..MostUrgent(10)
	Write !, "=== LONGEST UNFULFILLED (open, oldest) ===", ! Do ..LongestUnfulfilled(10)
	Write !, "=== SLA PERFORMANCE BY DEPARTMENT ===", ! Do ..SlaByDepartment()
	Write !, "=== TOP REQUEST TYPES ===", ! Do ..TopRequestTypes(10)
	Write !, "=== BY NEIGHBORHOOD ===", ! Do ..ByNeighborhood(15)
	Quit $$$OK
}

// ---------------------------------------------------------------
//  JSON siblings, for the web UI.
//
//  The methods above Write to a terminal device, which a web request
//  cannot use. These return data instead. Note that the SQL was always
//  the reusable part -- only the presentation differs.
// ---------------------------------------------------------------

/// Prepares and executes a query, throwing on either failure.
///
/// Bound values arrive as a counted local array (params(1..n), params = n)
/// rather than as a variable argument list, because that is what a dynamically
/// assembled WHERE clause naturally produces -- see SearchWhere().
ClassMethod RunQuery(sql As %String, ByRef params) As %SQL.StatementResult
{
	Set statement = ##class(%SQL.Statement).%New()
	Set sc = statement.%Prepare(sql)
	If $$$ISERR(sc) Throw ##class(%Exception.StatusException).CreateFromStatus(sc)

	// An empty array must not be expanded: params... with params undefined is
	// not the same as passing nothing.
	If $Get(params, 0) = 0 {
		Set resultSet = statement.%Execute()
	} Else {
		Set resultSet = statement.%Execute(params...)
	}
	If resultSet.%SQLCODE < 0 {
		Throw ##class(%Exception.SQL).CreateFromSQLCODE(resultSet.%SQLCODE, resultSet.%Message)
	}
	Quit resultSet
}

/// Drains a result set into an array of objects keyed by column name.
ClassMethod RowsFrom(resultSet As %SQL.StatementResult) As %DynamicArray
{
	Set rows = []
	Set metadata = resultSet.%GetMetadata()
	Set columnCount = metadata.columns.Count()
	While resultSet.%Next() {
		Set row = {}
		For i = 1:1:columnCount {
			Do row.%Set(metadata.columns.GetAt(i).colName, resultSet.%GetData(i))
		}
		Do rows.%Push(row)
	}
	Quit rows
}

/// Generic: runs a query and returns an array of objects keyed by column name.
/// Convenience form for a fixed, known argument list.
ClassMethod QueryToArray(sql As %String, args...) As %DynamicArray
{
	Kill params
	Set params = $Get(args, 0)
	For i = 1:1:params {
		Set params(i) = $Get(args(i))
	}
	Quit ..QueryArgs(sql, .params)
}

/// Same, with the bound values supplied as a counted local array.
ClassMethod QueryArgs(sql As %String, ByRef params) As %DynamicArray
{
	Quit ..RowsFrom(..RunQuery(sql, .params))
}

/// Headline counts for the stat tiles.
///
/// Takes the same filters as everything else, so the tiles describe the rows
/// currently on screen. A tile reading 25,000 above a table filtered to one
/// neighborhood is worse than no tile at all.
ClassMethod SummaryData(ByRef filters) As %DynamicObject
{
	Kill params
	Set where = ..SearchWhere(.params, .filters)
	Set rows = ..QueryArgs(
		"SELECT COUNT(*) AS total, "_
		"  SUM(CASE WHEN CaseStatus = 'Open' THEN 1 ELSE 0 END) AS openCount, "_
		"  SUM(CASE WHEN CaseStatus = 'Closed' THEN 1 ELSE 0 END) AS closedCount, "_
		"  SUM(CASE WHEN CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL "_
		"           AND SlaTargetDate < "_..AsOf()_" THEN 1 ELSE 0 END) AS breachedCount, "_
		"  SUM(CASE WHEN SlaTargetDate IS NULL THEN 1 ELSE 0 END) AS noSlaCount "_
		"FROM ProjA.ServiceRequest"_where, .params)
	Set summary = $Select(rows.%Size() > 0: rows.%Get(0), 1: {})
	// Ship the as-of instant with the counts so the UI can name the date it is
	// measuring against. A breach count means nothing without the moment it was
	// measured from, and a reader should not have to open the source to find it.
	Do summary.%Set("asOf", ..AsOfStamp())
	Quit summary
}

/// THE ATTENTION QUEUE: open cases already past their SLA deadline, worst first.
/// Cases with no SLA are excluded on purpose -- "overdue" is undefined without
/// a deadline, and counting them as on-time would flatter the numbers.
ClassMethod AttentionQueueData(top As %Integer = 100) As %DynamicArray
{
	Quit ..QueryToArray(
		"SELECT TOP ? CaseEnquiryId AS caseId, CaseTitle AS title, Reason AS reason, "_
		"  RequestType AS requestType, Department AS department, "_
		"  Neighborhood AS neighborhood, Location AS location, "_
		"  OpenedDate AS openedDate, SlaTargetDate AS slaTargetDate, "_
		"  ROUND(Latitude, 5) AS lat, ROUND(Longitude, 5) AS lng, "_
		"  DATEDIFF(hh, SlaTargetDate, "_..AsOf()_") AS hoursOverdue, "_
		"  DATEDIFF(dd, OpenedDate, "_..AsOf()_") AS daysOpen "_
		"FROM ProjA.ServiceRequest "_
		"WHERE CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL "_
		"  AND SlaTargetDate < "_..AsOf()_" "_
		"ORDER BY SlaTargetDate ASC", top)
}

/// Map points in a compact form: one array per point rather than an object,
/// which roughly halves the payload across ~25k rows. Detail for a clicked
/// dot comes from DetailData() instead of being shipped up front.
///
///   [ caseId, lat, lng, state ]   state: 0 closed, 1 open within SLA, 2 breached
ClassMethod MapData(ByRef filters, limit As %Integer = 0) As %DynamicObject
{
	Kill params
	Set where = ..SearchWhere(.params, .filters)
	Set resultSet = ..RunQuery(
		"SELECT "_$Select(limit > 0: "TOP "_(+limit)_" ", 1: "")_
		"  CaseEnquiryId, ROUND(Latitude, 5), ROUND(Longitude, 5), "_
		"  CASE WHEN CaseStatus = 'Closed' THEN 0 "_
		"       WHEN SlaTargetDate IS NOT NULL AND SlaTargetDate < "_..AsOf()_" THEN 2 "_
		"       ELSE 1 END "_
		"FROM ProjA.ServiceRequest"_where_
		"  AND Latitude IS NOT NULL AND Longitude IS NOT NULL "_
		"  AND Latitude <> 0 AND Longitude <> 0", .params)

	Set points = [], counts = [0, 0, 0]
	While resultSet.%Next() {
		// The unary + matters: %GetData() hands back strings, and a string
		// pushed into a %DynamicArray serializes as "2", not 2. The frontend
		// compares state with === , so quoted numbers would match nothing and
		// the map would come up empty with no error anywhere.
		Set state = +resultSet.%GetData(4)
		Do points.%Push([ (+resultSet.%GetData(1)), (+resultSet.%GetData(2)),
			(+resultSet.%GetData(3)), (state) ])
		Do counts.%Set(state, counts.%Get(state) + 1)
	}

	// Rows dropped for want of coordinates are reported, not hidden: a silently
	// short map reads as "this is everything" when it is not.
	Set plotted = points.%Size()
	Set total = ..CountMatching(.filters)
	Quit {
		"points": (points),
		"counts": (counts),
		"plotted": (plotted),
		"totalRows": (total),
		"missingCoordinates": (total - plotted)
	}
}

/// Everything about one case, for the map popup.
ClassMethod DetailData(caseId As %Integer) As %DynamicObject
{
	Set rows = ..QueryToArray(
		"SELECT CaseEnquiryId AS caseId, CaseTitle AS title, Subject AS subject, "_
		"  Reason AS reason, RequestType AS requestType, Queue AS queue, "_
		"  Department AS department, CaseStatus AS status, OnTime AS onTime, "_
		"  ClosureReason AS closureReason, Location AS location, "_
		"  Neighborhood AS neighborhood, Ward AS ward, Zipcode AS zipcode, "_
		"  OpenedDate AS openedDate, SlaTargetDate AS slaTargetDate, "_
		"  ClosedDate AS closedDate, Source AS source, "_
		"  DATEDIFF(hh, SlaTargetDate, "_..AsOf()_") AS hoursOverdue, "_
		"  DATEDIFF(dd, OpenedDate, "_..AsOf()_") AS daysOpen "_
		"FROM ProjA.ServiceRequest WHERE CaseEnquiryId = ?", caseId)
	Quit $Select(rows.%Size() > 0: rows.%Get(0), 1: {})
}

// ---------------------------------------------------------------
//  Search and filter
//
//  One WHERE builder feeds every filtered read -- search, map, trends,
//  resolution -- so a filter added once applies everywhere and the
//  panels can never disagree about which rows they are describing.
// ---------------------------------------------------------------

/// The "most overdue" ordering, also the fallback for an unrecognised sort key.
///
/// Tier 0 is an open case already past its deadline -- the attention queue --
/// worst first; tier 1 is everything else with a deadline; tier 2 is the cases
/// that never had one. The status test is what makes this ordering hold up when
/// urgency is combined with NO SLA filter, which is the dashboard's default
/// view: ordering by SlaTargetDate alone would fill the top of the list with
/// long-closed June cases, the exact opposite of an attention queue.
///
/// A method rather than a Parameter because it has to splice in ..AsOf(), and a
/// class Parameter must be a compile-time literal.
ClassMethod UrgencySort() As %String [ CodeMode = expression ]
{
"CASE WHEN CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL AND SlaTargetDate < "_..AsOf()_" THEN 0 WHEN SlaTargetDate IS NULL THEN 2 ELSE 1 END, SlaTargetDate ASC"
}

/// Any Monday. Fixes the grid that week buckets snap to.
/// Deliberately far in the past so that (date - anchor) is never negative,
/// which keeps the modulo in BucketKey() free of sign-convention questions.
Parameter WEEKANCHOR = "2000-01-03";

/// Maps an API-facing key to a real column name.
///
/// A whitelist, not string interpolation: groupBy and sort arrive from a query
/// string and land in GROUP BY / ORDER BY, where no amount of parameter binding
/// downstream would help. Anything unrecognised returns empty, and callers
/// substitute their own default rather than passing the text through.
ClassMethod GroupColumn(key As %String) As %String
{
	Quit $Case($ZConvert($ZStrip(key, "<>W"), "L"),
		"department": "Department",
		"neighborhood": "Neighborhood",
		"reason": "Reason",
		"requesttype": "RequestType",
		"queue": "Queue",
		"source": "Source",
		"ward": "Ward",
		"zipcode": "Zipcode",
		"status": "CaseStatus",
		: "")
}

/// ORDER BY clause for a sort key. Whitelisted for the same reason as above.
///
/// The urgency sort needs the CASE: SlaTargetDate ASC alone puts NULLs first in
/// IRIS, so the ~3,000 cases with no deadline at all would head up a list whose
/// whole purpose is "most overdue first".
ClassMethod SortClause(key As %String) As %String
{
	Quit $Case($ZConvert($ZStrip(key, "<>W"), "L"),
		"urgency": ..UrgencySort(),
		"newest": "OpenedDate DESC",
		"oldest": "OpenedDate ASC",
		"neighborhood": "Neighborhood ASC, OpenedDate DESC",
		"department": "Department ASC, OpenedDate DESC",
		"longest": "CASE WHEN ClosedDate IS NULL THEN 0 ELSE 1 END, OpenedDate ASC",
		: ..UrgencySort())
}

/// "2026-07-01" -> "2026-07-01 00:00:00", or " 23:59:59" for an upper bound.
///
/// A malformed date returns empty, which drops the bound entirely. The
/// alternative -- passing the text through to SQL -- would compare a bad
/// timestamp and quietly return zero rows, which reads as "no such requests"
/// rather than "your date was not understood".
ClassMethod ToDateBound(raw As %String, upper As %Boolean = 0) As %String
{
	Set raw = $ZStrip($Get(raw), "<>W")
	If $Length(raw) < 10 Quit ""
	Set raw = $Extract(raw, 1, 10)
	Try {
		Set horolog = $ZDateH(raw, 3)
	} Catch {
		Set horolog = ""
	}
	If horolog = "" Quit ""
	Quit raw_$Select(upper: " 23:59:59", 1: " 00:00:00")
}

/// Builds the WHERE clause shared by every filtered read, appending one bound
/// value to params for each ? emitted. Values are always bound, never
/// concatenated; only whitelisted column names are interpolated.
///
/// Starts at "WHERE 1=1" so callers can append their own AND conditions
/// without caring whether any filters were supplied.
ClassMethod SearchWhere(ByRef params, ByRef filters) As %String
{
	Set where = " WHERE 1=1"
	Set n = $Get(params, 0)

	// Exact matches on the coded columns.
	For key = "neighborhood", "department", "reason", "requestType", "source", "ward", "status" {
		Set value = $ZStrip($Get(filters(key)), "<>W")
		If value = "" Continue
		Set where = where_" AND "_..GroupColumn(key)_" = ?"
		Set n = n + 1, params(n) = value
	}

	// SLA state. Computed live against the deadline rather than read from the
	// as-loaded OnTime flag, so it agrees with the attention queue.
	Set sla = $ZConvert($ZStrip($Get(filters("sla")), "<>W"), "L")
	If sla = "breached" {
		Set where = where_" AND CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL"_
			" AND SlaTargetDate < "_..AsOf()_""
	} ElseIf sla = "withinsla" {
		Set where = where_" AND CaseStatus = 'Open'"_
			" AND (SlaTargetDate IS NULL OR SlaTargetDate >= "_..AsOf()_")"
	} ElseIf sla = "missed" {
		// Already closed, but closed after its deadline.
		Set where = where_" AND CaseStatus = 'Closed' AND SlaTargetDate IS NOT NULL"_
			" AND ClosedDate > SlaTargetDate"
	} ElseIf sla = "metsla" {
		Set where = where_" AND CaseStatus = 'Closed' AND SlaTargetDate IS NOT NULL"_
			" AND ClosedDate <= SlaTargetDate"
	} ElseIf sla = "nosla" {
		Set where = where_" AND SlaTargetDate IS NULL"
	}

	// Opened-date range.
	Set fromBound = ..ToDateBound($Get(filters("openedFrom")), 0)
	If fromBound '= "" {
		Set where = where_" AND OpenedDate >= ?"
		Set n = n + 1, params(n) = fromBound
	}
	Set toBound = ..ToDateBound($Get(filters("openedTo")), 1)
	If toBound '= "" {
		Set where = where_" AND OpenedDate <= ?"
		Set n = n + 1, params(n) = toBound
	}

	// Free text across the columns a staff member would actually recognise.
	//
	// [ is IRIS SQL's "contains" operator, used in preference to LIKE '%x%' so
	// that a % or _ typed into the search box matches literally instead of
	// silently behaving as a wildcard. UPPER on both sides makes it
	// case-insensitive without a collation assumption.
	Set text = $ZConvert($ZStrip($Get(filters("text")), "<>W"), "U")
	If text '= "" {
		Set clause = "UPPER(CaseTitle) [ ? OR UPPER(RequestType) [ ? "_
			"OR UPPER(Location) [ ? OR UPPER(StreetName) [ ? OR UPPER(Reason) [ ?"
		For i = 1:1:5 {
			Set n = n + 1, params(n) = text
		}
		// Staff paste case numbers into search boxes. Match one exactly when the
		// term is numeric, so a case ID finds its case instead of nothing.
		If $IsValidNum(text) {
			Set clause = clause_" OR CaseEnquiryId = ?"
			Set n = n + 1, params(n) = +text
		}
		Set where = where_" AND ("_clause_")"
	}

	Set params = n
	Quit where
}

/// How many rows match the current filters.
ClassMethod CountMatching(ByRef filters) As %Integer
{
	Kill params
	Set where = ..SearchWhere(.params, .filters)
	Set rows = ..QueryArgs("SELECT COUNT(*) AS n FROM ProjA.ServiceRequest"_where, .params)
	Quit $Select(rows.%Size() > 0: +rows.%Get(0).n, 1: 0)
}

/// SEARCH: the filtered request list.
///
/// Returns the matching total alongside the page of rows, so the UI can say
/// "1,204 matches, showing 200" rather than implying that 200 is all there is.
ClassMethod SearchData(ByRef filters, top As %Integer = 200, sort As %String = "urgency") As %DynamicObject
{
	Set top = $Select(top < 1: 1, top > 2000: 2000, 1: +top)
	Kill params
	Set where = ..SearchWhere(.params, .filters)

	// TOP is interpolated after clamping rather than bound. A bound TOP would be
	// parameter 1, ahead of every filter value, and that ordering is easy to get
	// wrong when the WHERE clause is assembled elsewhere.
	Set rows = ..QueryArgs(
		"SELECT TOP "_(+top)_" CaseEnquiryId AS caseId, CaseTitle AS title, "_
		"  Reason AS reason, RequestType AS requestType, Department AS department, "_
		"  Neighborhood AS neighborhood, Location AS location, CaseStatus AS status, "_
		"  OpenedDate AS openedDate, SlaTargetDate AS slaTargetDate, ClosedDate AS closedDate, "_
		"  Source AS source, ROUND(Latitude, 5) AS lat, ROUND(Longitude, 5) AS lng, "_
		"  DATEDIFF(hh, SlaTargetDate, "_..AsOf()_") AS hoursOverdue, "_
		"  DATEDIFF(dd, OpenedDate, "_..AsOf()_") AS daysOpen, "_
		"  DATEDIFF(hh, OpenedDate, ClosedDate) AS hoursToClose "_
		"FROM ProjA.ServiceRequest"_where_
		" ORDER BY "_..SortClause(sort), .params)

	Quit {
		"total": (..CountMatching(.filters)),
		"returned": (rows.%Size()),
		"limit": (top),
		"sort": (sort),
		"rows": (rows)
	}
}

/// Distinct values for the filter controls, commonest first, each with its row
/// count so the UI can show how much a choice would narrow things.
ClassMethod FilterOptionsData() As %DynamicObject
{
	Set out = {}
	// %EXACT() around the grouped column matters for display. A %String property
	// groups under SQLUPPER collation by default, so a bare "GROUP BY Neighborhood"
	// hands back DORCHESTER rather than Dorchester, and the dropdown would shout.
	// Matching stays case-insensitive either way, because the filter comparison
	// still goes through the collated index.
	For key = "neighborhood", "department", "reason", "source", "requestType", "ward" {
		Set column = ..GroupColumn(key)
		Do out.%Set(key, ..QueryToArray(
			"SELECT %EXACT("_column_") AS value, COUNT(*) AS n "_
			"FROM ProjA.ServiceRequest "_
			"WHERE "_column_" IS NOT NULL AND "_column_" <> '' "_
			"GROUP BY %EXACT("_column_") ORDER BY COUNT(*) DESC"))
	}

	// The loaded window, so the date pickers can bound themselves to real data
	// instead of offering years that would always return nothing.
	Set span = ..QueryToArray(
		"SELECT MIN(OpenedDate) AS earliest, MAX(OpenedDate) AS latest "_
		"FROM ProjA.ServiceRequest WHERE OpenedDate IS NOT NULL")
	Do out.%Set("dateRange", $Select(span.%Size() > 0: span.%Get(0), 1: {}))
	Quit out
}

// ---------------------------------------------------------------
//  Trends over time
// ---------------------------------------------------------------

/// Counts per calendar day for one date column, honouring the current filters.
///
/// Buckets on SUBSTRING(column, 1, 10) rather than a date-conversion function:
/// a %TimeStamp is stored as "YYYY-MM-DD HH:MM:SS", so its first ten characters
/// are already the calendar day, and string slicing behaves identically on every
/// IRIS version. Gap filling and coarser buckets are done in ObjectScript below,
/// which keeps this query trivial.
ClassMethod DailyCounts(column As %String, ByRef filters, Output counts As %Integer) As %Status
{
	Kill counts
	Kill params
	Set where = ..SearchWhere(.params, .filters)
	Set resultSet = ..RunQuery(
		"SELECT SUBSTRING("_column_", 1, 10) AS bucketDay, COUNT(*) AS n "_
		"FROM ProjA.ServiceRequest"_where_" AND "_column_" IS NOT NULL "_
		"GROUP BY SUBSTRING("_column_", 1, 10)", .params)
	While resultSet.%Next() {
		Set day = resultSet.%GetData(1)
		If day = "" Continue
		Set counts(day) = +resultSet.%GetData(2)
	}
	Quit $$$OK
}

/// The bucket a given $Horolog day belongs to, as a label.
ClassMethod BucketKey(horolog As %Integer, bucket As %String) As %String
{
	If bucket = "month" Quit $Extract($ZDate(horolog, 3), 1, 7)
	If bucket = "week" {
		Set anchor = $ZDateH(..#WEEKANCHOR, 3)
		Quit $ZDate(horolog - ((horolog - anchor) # 7), 3)
	}
	Quit $ZDate(horolog, 3)
}

/// TRENDS: requests opened vs. closed over time, plus the running net change
/// in backlog.
///
/// Every day in the range is emitted, including days with no activity at all.
/// Letting a quiet day fall out of the series would draw a line straight from
/// the day before to the day after and make the gap look like steady volume.
///
/// cumulativeNet is the net change in open cases since the start of the window,
/// NOT the absolute backlog: cases opened before the first loaded day are not in
/// this data, so the true standing backlog is this figure plus an unknown
/// constant. It is reported as a delta rather than dressed up as a total.
ClassMethod TrendData(ByRef filters, bucket As %String = "day") As %DynamicObject
{
	Set bucket = $Case($ZConvert($ZStrip(bucket, "<>W"), "L"),
		"week": "week", "month": "month", : "day")

	Do ..DailyCounts("OpenedDate", .filters, .openedByDay)
	Do ..DailyCounts("ClosedDate", .filters, .closedByDay)

	// Range spans both series: the last closure can fall after the last opening.
	Set firstDay = $Order(openedByDay(""))
	Set firstClosed = $Order(closedByDay(""))
	If (firstDay = "") || ((firstClosed '= "") && (firstClosed < firstDay)) {
		Set firstDay = firstClosed
	}
	Set lastDay = $Order(openedByDay(""), -1)
	Set lastClosed = $Order(closedByDay(""), -1)
	If (lastClosed '= "") && (lastClosed > lastDay) Set lastDay = lastClosed

	Set series = []
	If firstDay = "" {
		Quit {"bucket": (bucket), "series": (series), "totals":
			{"opened": 0, "closed": 0, "netChange": 0}}
	}

	Set totalOpened = 0, totalClosed = 0, runningNet = 0
	Set currentKey = "", currentOpened = 0, currentClosed = 0

	For horolog = $ZDateH(firstDay, 3):1:$ZDateH(lastDay, 3) {
		Set day = $ZDate(horolog, 3)
		Set key = ..BucketKey(horolog, bucket)
		If (currentKey '= "") && (key '= currentKey) {
			Set runningNet = runningNet + currentOpened - currentClosed
			Do series.%Push({
				"bucket": (currentKey),
				"opened": (currentOpened),
				"closed": (currentClosed),
				"netChange": (currentOpened - currentClosed),
				"cumulativeNet": (runningNet)
			})
			Set currentOpened = 0, currentClosed = 0
		}
		Set currentKey = key
		Set currentOpened = currentOpened + $Get(openedByDay(day), 0)
		Set currentClosed = currentClosed + $Get(closedByDay(day), 0)
		Set totalOpened = totalOpened + $Get(openedByDay(day), 0)
		Set totalClosed = totalClosed + $Get(closedByDay(day), 0)
	}
	// The loop above only flushes a bucket when the next one starts, so the last
	// one is still pending here.
	If currentKey '= "" {
		Set runningNet = runningNet + currentOpened - currentClosed
		Do series.%Push({
			"bucket": (currentKey),
			"opened": (currentOpened),
			"closed": (currentClosed),
			"netChange": (currentOpened - currentClosed),
			"cumulativeNet": (runningNet)
		})
	}

	Quit {
		"bucket": (bucket),
		"from": (firstDay),
		"to": (lastDay),
		"series": (series),
		"totals": {
			"opened": (totalOpened),
			"closed": (totalClosed),
			"netChange": (totalOpened - totalClosed)
		}
	}
}

// ---------------------------------------------------------------
//  Resolution times and closure patterns
// ---------------------------------------------------------------

/// A percentile from a distribution held as dist(group, hours) = case count.
///
/// Local array subscripts iterate in numeric order, so walking them with $Order
/// accumulates the distribution in sorted order for free -- no list to build and
/// sort, and no SQL median function to depend on.
ClassMethod Percentile(ByRef dist, group As %String, total As %Integer, fraction As %Double) As %Integer
{
	If total < 1 Quit ""
	Set target = total * fraction
	Set seen = 0, hours = "", last = ""
	For {
		Set hours = $Order(dist(group, hours))
		If hours = "" Quit
		Set last = hours
		Set seen = seen + dist(group, hours)
		If seen >= target Quit
	}
	Quit last
}

/// RESOLUTION: how long closed cases actually took, grouped by department,
/// neighborhood, reason, request type or source.
///
/// The averages come back from SQL, but median, 90th percentile and the duration
/// histogram are computed here in ObjectScript. Streaming ~11,000 closed cases
/// into a subscripted distribution is both cheaper than a self-joined SQL median
/// and portable across IRIS versions, which the aggregate functions are not.
///
/// Closure-reason text is deliberately not grouped on: every closed case in this
/// extract carries the same boilerplate ("Case Closed. Closed date : ..."), so
/// 11,412 distinct strings describe nothing. Closure pattern here means the shape
/// of the duration distribution and whether the deadline was met.
ClassMethod ResolutionData(ByRef filters, groupBy As %String = "department", top As %Integer = 25) As %DynamicObject
{
	Set column = ..GroupColumn(groupBy)
	If column = "" Set column = "Department", groupBy = "department"
	Set top = $Select(top < 1: 1, top > 200: 200, 1: +top)

	Kill params
	Set where = ..SearchWhere(.params, .filters)
	Set resultSet = ..RunQuery(
		"SELECT "_column_" AS grp, "_
		"  DATEDIFF(hh, OpenedDate, ClosedDate) AS hoursToClose, "_
		"  CASE WHEN SlaTargetDate IS NOT NULL AND ClosedDate > SlaTargetDate "_
		"       THEN 1 ELSE 0 END AS lateFlag, "_
		"  CASE WHEN SlaTargetDate IS NULL THEN 1 ELSE 0 END AS noSlaFlag "_
		"FROM ProjA.ServiceRequest"_where_
		" AND CaseStatus = 'Closed' AND ClosedDate IS NOT NULL AND OpenedDate IS NOT NULL",
		.params)

	// Bucket edges in hours: same day, up to 3 days, up to a week, up to a
	// fortnight, longer.
	Set edges = $ListBuild(24, 72, 168, 336)
	Set anomalies = 0, grandTotal = 0

	While resultSet.%Next() {
		Set group = resultSet.%GetData(1)
		If group = "" Set group = "(unspecified)"
		Set hours = +resultSet.%GetData(2)

		// Closed before it was opened. Real in this extract, and averaging it in
		// would drag a department's mean below zero, so it is counted and
		// reported rather than silently included or silently dropped.
		If hours < 0 {
			Set anomalies = anomalies + 1
			Continue
		}

		Set grandTotal = grandTotal + 1
		Set stat(group, "n") = $Get(stat(group, "n"), 0) + 1
		Set stat(group, "sum") = $Get(stat(group, "sum"), 0) + hours
		Set stat(group, "late") = $Get(stat(group, "late"), 0) + resultSet.%GetData(3)
		Set stat(group, "nosla") = $Get(stat(group, "nosla"), 0) + resultSet.%GetData(4)
		Set dist(group, hours) = $Get(dist(group, hours), 0) + 1

		Set slot = 5
		For i = 1:1:4 {
			If hours <= $List(edges, i) {
				Set slot = i
				Quit
			}
		}
		Set stat(group, "b", slot) = $Get(stat(group, "b", slot), 0) + 1
		Set overall("b", slot) = $Get(overall("b", slot), 0) + 1
	}

	// Rank by volume: build the inverse index, then walk it descending.
	Set group = ""
	For {
		Set group = $Order(stat(group))
		If group = "" Quit
		Set byVolume(stat(group, "n"), group) = ""
	}

	Set rows = [], shown = 0
	Set count = ""
	For {
		Set count = $Order(byVolume(count), -1)
		If count = "" Quit
		Set group = ""
		For {
			Set group = $Order(byVolume(count, group))
			If (group = "") || (shown >= top) Quit
			Set n = stat(group, "n")
			Set withSla = n - $Get(stat(group, "nosla"), 0)
			Do rows.%Push({
				"group": (group),
				"closed": (n),
				"avgHours": ($Number(stat(group, "sum") / n, 1)),
				"medianHours": (..Percentile(.dist, group, n, 0.5)),
				"p90Hours": (..Percentile(.dist, group, n, 0.9)),
				"lateClosures": ($Get(stat(group, "late"), 0)),
				"withSla": (withSla),
				"pctLate": ($Select(withSla > 0:
					$Number(100 * $Get(stat(group, "late"), 0) / withSla, 1), 1: "")),
				"buckets": [
					($Get(stat(group, "b", 1), 0)), ($Get(stat(group, "b", 2), 0)),
					($Get(stat(group, "b", 3), 0)), ($Get(stat(group, "b", 4), 0)),
					($Get(stat(group, "b", 5), 0))
				]
			})
			Set shown = shown + 1
		}
		If shown >= top Quit
	}

	Quit {
		"groupBy": (groupBy),
		"closedTotal": (grandTotal),
		"negativeDuration": (anomalies),
		"bucketLabels": ["<= 24h", "1-3 days", "3-7 days", "1-2 weeks", "> 2 weeks"],
		"overallBuckets": [
			($Get(overall("b", 1), 0)), ($Get(overall("b", 2), 0)),
			($Get(overall("b", 3), 0)), ($Get(overall("b", 4), 0)),
			($Get(overall("b", 5), 0))
		],
		"rows": (rows)
	}
}

/// Single scalar from a query. Small helper, used for counts.
ClassMethod Sql1(sql As %String, args...) As %String
{
	Set statement = ##class(%SQL.Statement).%New()
	Set sc = statement.%Prepare(sql)
	If $$$ISERR(sc) Quit ""
	Set resultSet = statement.%Execute(args...)
	If resultSet.%Next() Quit resultSet.%GetData(1)
	Quit ""
}

Storage Default
{
<Data name="ServiceRequestDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>CaseEnquiryId</Value>
</Value>
<Value name="3">
<Value>OpenedDate</Value>
</Value>
<Value name="4">
<Value>SlaTargetDate</Value>
</Value>
<Value name="5">
<Value>ClosedDate</Value>
</Value>
<Value name="6">
<Value>OnTime</Value>
</Value>
<Value name="7">
<Value>CaseStatus</Value>
</Value>
<Value name="8">
<Value>ClosureReason</Value>
</Value>
<Value name="9">
<Value>CaseTitle</Value>
</Value>
<Value name="10">
<Value>Subject</Value>
</Value>
<Value name="11">
<Value>Reason</Value>
</Value>
<Value name="12">
<Value>RequestType</Value>
</Value>
<Value name="13">
<Value>Queue</Value>
</Value>
<Value name="14">
<Value>Department</Value>
</Value>
<Value name="15">
<Value>SubmittedPhoto</Value>
</Value>
<Value name="16">
<Value>ClosedPhoto</Value>
</Value>
<Value name="17">
<Value>Location</Value>
</Value>
<Value name="18">
<Value>FireDistrict</Value>
</Value>
<Value name="19">
<Value>PwdDistrict</Value>
</Value>
<Value name="20">
<Value>CityCouncilDistrict</Value>
</Value>
<Value name="21">
<Value>PoliceDistrict</Value>
</Value>
<Value name="22">
<Value>Neighborhood</Value>
</Value>
<Value name="23">
<Value>NeighborhoodServicesDistrict</Value>
</Value>
<Value name="24">
<Value>Ward</Value>
</Value>
<Value name="25">
<Value>Precinct</Value>
</Value>
<Value name="26">
<Value>StreetName</Value>
</Value>
<Value name="27">
<Value>Zipcode</Value>
</Value>
<Value name="28">
<Value>Latitude</Value>
</Value>
<Value name="29">
<Value>Longitude</Value>
</Value>
<Value name="30">
<Value>Source</Value>
</Value>
</Data>
<DataLocation>^ProjA.ServiceRequestD</DataLocation>
<DefaultData>ServiceRequestDefaultData</DefaultData>
<IdLocation>^ProjA.ServiceRequestD</IdLocation>
<IndexLocation>^ProjA.ServiceRequestI</IndexLocation>
<StreamLocation>^ProjA.ServiceRequestS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
