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
	Set endPoint = $Select(..ClosedDate '= "": ..ClosedDate, 1: $ZDateTime($Horolog, 3))
	Quit ..HoursBetween(..OpenedDate, endPoint)
}

/// Positive = past its SLA deadline by this many hours. Empty when no SLA.
Method HoursOverdue() As %Integer
{
	If ..SlaTargetDate = "" Quit ""
	Set endPoint = $Select(..ClosedDate '= "": ..ClosedDate, 1: $ZDateTime($Horolog, 3))
	Quit ..HoursBetween(..SlaTargetDate, endPoint)
}

/// Runs a query and prints it with column headers.
ClassMethod PrintQuery(sql As %String, args...) As %Status
{
	Set statement = ##class(%SQL.Statement).%New()
	Set sc = statement.%Prepare(sql)
	If $$$ISERR(sc) Quit sc
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
		"       DATEDIFF(hh, SlaTargetDate, CURRENT_TIMESTAMP) AS HoursOverdue "_
		"FROM ProjA.ServiceRequest "_
		"WHERE CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL "_
		"  AND SlaTargetDate < CURRENT_TIMESTAMP "_
		"ORDER BY SlaTargetDate ASC", top)
}

/// MOST TIME UNFULFILLED: still-open cases by age, oldest first.
ClassMethod LongestUnfulfilled(top As %Integer = 20) As %Status
{
	Quit ..PrintQuery(
		"SELECT TOP ? CaseEnquiryId, CaseTitle, Department, Neighborhood, OpenedDate, "_
		"       DATEDIFF(dd, OpenedDate, CURRENT_TIMESTAMP) AS DaysOpen "_
		"FROM ProjA.ServiceRequest "_
		"WHERE CaseStatus = 'Open' "_
		"ORDER BY OpenedDate ASC", top)
}

/// Which departments are worst at hitting their SLA?
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
ClassMethod Summary() As %Status
{
	Quit ..PrintQuery(
		"SELECT COUNT(*) AS Rows, "_
		"       SUM(CASE WHEN CaseStatus = 'Open' THEN 1 ELSE 0 END) AS Open, "_
		"       SUM(CASE WHEN CaseStatus = 'Closed' THEN 1 ELSE 0 END) AS Closed, "_
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

/// Generic: runs a query and returns an array of objects keyed by column name.
ClassMethod QueryToArray(sql As %String, args...) As %DynamicArray
{
	Set rows = []
	Set statement = ##class(%SQL.Statement).%New()
	Set sc = statement.%Prepare(sql)
	If $$$ISERR(sc) Throw ##class(%Exception.StatusException).CreateFromStatus(sc)

	Set resultSet = statement.%Execute(args...)
	If resultSet.%SQLCODE < 0 {
		Throw ##class(%Exception.SQL).CreateFromSQLCODE(resultSet.%SQLCODE, resultSet.%Message)
	}

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

/// Headline counts for the stat tiles.
ClassMethod SummaryData() As %DynamicObject
{
	Set rows = ..QueryToArray(
		"SELECT COUNT(*) AS total, "_
		"  SUM(CASE WHEN CaseStatus = 'Open' THEN 1 ELSE 0 END) AS openCount, "_
		"  SUM(CASE WHEN CaseStatus = 'Closed' THEN 1 ELSE 0 END) AS closedCount, "_
		"  SUM(CASE WHEN CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL "_
		"           AND SlaTargetDate < CURRENT_TIMESTAMP THEN 1 ELSE 0 END) AS breachedCount, "_
		"  SUM(CASE WHEN SlaTargetDate IS NULL THEN 1 ELSE 0 END) AS noSlaCount "_
		"FROM ProjA.ServiceRequest")
	Quit $Select(rows.%Size() > 0: rows.%Get(0), 1: {})
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
		"  DATEDIFF(hh, SlaTargetDate, CURRENT_TIMESTAMP) AS hoursOverdue, "_
		"  DATEDIFF(dd, OpenedDate, CURRENT_TIMESTAMP) AS daysOpen "_
		"FROM ProjA.ServiceRequest "_
		"WHERE CaseStatus = 'Open' AND SlaTargetDate IS NOT NULL "_
		"  AND SlaTargetDate < CURRENT_TIMESTAMP "_
		"ORDER BY SlaTargetDate ASC", top)
}

/// Map points in a compact form: one array per point rather than an object,
/// which roughly halves the payload across ~25k rows. Detail for a clicked
/// dot comes from DetailData() instead of being shipped up front.
///
///   [ caseId, lat, lng, state ]   state: 0 closed, 1 open within SLA, 2 breached
ClassMethod MapData(limit As %Integer = 0) As %DynamicObject
{
	Set sql =
		"SELECT "_$Select(limit > 0: "TOP "_(+limit)_" ", 1: "")_
		"  CaseEnquiryId, ROUND(Latitude, 5), ROUND(Longitude, 5), "_
		"  CASE WHEN CaseStatus = 'Closed' THEN 0 "_
		"       WHEN SlaTargetDate IS NOT NULL AND SlaTargetDate < CURRENT_TIMESTAMP THEN 2 "_
		"       ELSE 1 END "_
		"FROM ProjA.ServiceRequest "_
		"WHERE Latitude IS NOT NULL AND Longitude IS NOT NULL "_
		"  AND Latitude <> 0 AND Longitude <> 0"

	Set statement = ##class(%SQL.Statement).%New()
	Set sc = statement.%Prepare(sql)
	If $$$ISERR(sc) Throw ##class(%Exception.StatusException).CreateFromStatus(sc)
	Set resultSet = statement.%Execute()
	If resultSet.%SQLCODE < 0 {
		Throw ##class(%Exception.SQL).CreateFromSQLCODE(resultSet.%SQLCODE, resultSet.%Message)
	}

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
	Set total = +..Sql1("SELECT COUNT(*) FROM ProjA.ServiceRequest")
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
		"  DATEDIFF(hh, SlaTargetDate, CURRENT_TIMESTAMP) AS hoursOverdue, "_
		"  DATEDIFF(dd, OpenedDate, CURRENT_TIMESTAMP) AS daysOpen "_
		"FROM ProjA.ServiceRequest WHERE CaseEnquiryId = ?", caseId)
	Quit $Select(rows.%Size() > 0: rows.%Get(0), 1: {})
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
