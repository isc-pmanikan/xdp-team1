/// A minimal persistent class: stored in the database and queryable via SQL
/// as the table tutorial.Person.
Class tutorial.Person Extends %Persistent
{

Property Name As %String(MAXLEN = 100) [ Required ];

Property Email As %String(MAXLEN = 255);

Property DateOfBirth As %Date;

/// Instance method — called on an object with dot syntax: person.Describe()
/// Inside a method, ".." refers to this object's own properties and methods.
Method Describe() As %String
{
	Set text = ..Name
	If ..Email '= "" {
		Set text = text_" <"_..Email_">"
	}
	If ..DateOfBirth '= "" {
		Set text = text_", born "_$ZDate(..DateOfBirth, 3)
	}
	Quit text
}

/// Class method — called on the class itself, no object needed:
///   Do ##class(tutorial.Person).Add("Ada Lovelace")
/// Returns a %Status, which is how IRIS reports success/failure.
ClassMethod Add(name As %String, email As %String = "", dateOfBirth As %Date = "") As %Status
{
	Set person = ..%New()
	Set person.Name = name
	Set person.Email = email
	Set person.DateOfBirth = dateOfBirth
	Quit person.%Save()
}

/// Loads one row by ID and writes its description to the terminal.
ClassMethod Show(id As %Integer) As %Status
{
	If '..%ExistsId(id) {
		Write "No Person with ID ", id, !
		Quit $$$OK
	}
	Set person = ..%OpenId(id)
	Write person.Describe(), !
	Quit $$$OK
}

/// Runs a query with embedded SQL over the same data.
ClassMethod ShowAll() As %Status
{
	Set statement = ##class(%SQL.Statement).%New()
	Set status = statement.%Prepare("SELECT ID, Name, Email FROM tutorial.Person ORDER BY Name")
	If $$$ISERR(status) Quit status

	Set resultSet = statement.%Execute()
	While resultSet.%Next() {
		Write resultSet.%Get("ID"), $Char(9), resultSet.%Get("Name"), $Char(9), resultSet.%Get("Email"), !
	}
	Quit $$$OK
}

/// Entry point to prove the whole thing works:
///   Do ##class(tutorial.Person).Test()
ClassMethod Test() As %Status
{
	Do ..%KillExtent()

	Set status = ..Add("Alice Chen", "alice@example.com", $ZDateH("1990-04-17", 3))
	If $$$ISERR(status) Quit status

	Set status = ..Add("Bob Ruiz", "bob@example.com")
	If $$$ISERR(status) Quit status

	Write "All people:", !
	Quit ..ShowAll()
}

Storage Default
{
<Data name="PersonDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Name</Value>
</Value>
<Value name="3">
<Value>Email</Value>
</Value>
<Value name="4">
<Value>DateOfBirth</Value>
</Value>
</Data>
<DataLocation>^tutorial.PersonD</DataLocation>
<DefaultData>PersonDefaultData</DefaultData>
<IdLocation>^tutorial.PersonD</IdLocation>
<IndexLocation>^tutorial.PersonI</IndexLocation>
<StreamLocation>^tutorial.PersonS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
