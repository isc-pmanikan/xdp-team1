/// REST API for the Boston 311 dashboard.
///
/// IRIS is already an HTTP server, so no separate backend process is needed --
/// the browser talks to IRIS directly and the queries run in the same process
/// as the data.
///
/// IMPORTANT: these routes do not exist until a Web Application is created that
/// maps a URL prefix to this dispatch class. Management Portal ->
/// System Administration -> Security -> Applications -> Web Applications -> New:
///
///     Name             /projA/api
///     Namespace        USER
///     Enable           REST  (Dispatch Class = ProjA.API)
///     Authentication   Unauthenticated  (development only -- see below)
///
/// Without that mapping every URL below returns 404 no matter how correct this
/// class is. Unauthenticated means anyone who can reach port 52773 can read the
/// data; fine on a laptop, not something to carry into a shared environment.
Class ProjA.API Extends %CSP.REST
{

/// Answers CORS preflight, so a frontend dev server on another port can call
/// these endpoints. Unnecessary if the UI is served from IRIS itself.
Parameter HandleCorsRequest = 1;

Parameter CHARSET = "utf-8";

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
<Route Url="/summary" Method="GET" Call="GetSummary"/>
<Route Url="/queue" Method="GET" Call="GetQueue"/>
<Route Url="/map" Method="GET" Call="GetMap"/>
<Route Url="/request/:caseId" Method="GET" Call="GetRequest"/>
</Routes>
}

/// GET /summary -> headline counts for the stat tiles
ClassMethod GetSummary() As %Status
{
	Try {
		Do ..WriteJson(##class(ProjA.ServiceRequest).SummaryData())
	} Catch ex {
		Do ..WriteError(ex)
	}
	Quit $$$OK
}

/// GET /queue?top=100 -> the attention queue
ClassMethod GetQueue() As %Status
{
	Try {
		Set top = ..IntParam("top", 100, 1, 1000)
		Do ..WriteJson(##class(ProjA.ServiceRequest).AttentionQueueData(top))
	} Catch ex {
		Do ..WriteError(ex)
	}
	Quit $$$OK
}

/// GET /map?limit=0 -> every plottable point, compactly
ClassMethod GetMap() As %Status
{
	Try {
		Set limit = ..IntParam("limit", 0, 0, 100000)
		Do ..WriteJson(##class(ProjA.ServiceRequest).MapData(limit))
	} Catch ex {
		Do ..WriteError(ex)
	}
	Quit $$$OK
}

/// GET /request/101006733826 -> full detail for one case
/// Written as a nested If/Else rather than guard clauses, because neither form
/// of Quit does what a guard clause needs inside a Try block: an argumentless
/// Quit leaves the block instead of the method, and a Quit WITH an argument is
/// not legal in a Try or Catch at all. The single Quit is after the Catch.
ClassMethod GetRequest(caseId As %String) As %Status
{
	Try {
		If '$IsValidNum(caseId) {
			Set %response.Status = "400 Bad Request"
			Set body = {"error": "caseId must be numeric"}
			Do ..WriteJson(body)
		} Else {
			Set detail = ##class(ProjA.ServiceRequest).DetailData(+caseId)
			If detail.%Size() = 0 {
				Set %response.Status = "404 Not Found"
				Set body = {"error": "no such case"}
				Do ..WriteJson(body)
			} Else {
				Do ..WriteJson(detail)
			}
		}
	} Catch ex {
		Do ..WriteError(ex)
	}
	Quit $$$OK
}

// ---------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------

ClassMethod WriteJson(payload As %DynamicAbstractObject) As %Status
{
	Set %response.ContentType = "application/json"
	Do payload.%ToJSON()
	Quit $$$OK
}

/// Reports the failure as JSON instead of an IRIS HTML error page, so the
/// frontend can surface something useful.
ClassMethod WriteError(ex As %Exception.AbstractException) As %Status
{
	Set %response.Status = "500 Internal Server Error"
	Set %response.ContentType = "application/json"
	Set body = {"error": (ex.DisplayString())}
	Do body.%ToJSON()
	Quit $$$OK
}

/// Clamped integer query parameter. Anything unparseable falls back to the
/// default rather than reaching SQL.
ClassMethod IntParam(name As %String, default As %Integer, min As %Integer, max As %Integer) As %Integer
{
	Set raw = $Get(%request.Data(name, 1))
	If (raw = "") || '$IsValidNum(raw) Quit default
	Set value = +raw
	If value < min Quit min
	If value > max Quit max
	Quit value
}

}
