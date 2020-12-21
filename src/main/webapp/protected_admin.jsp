<%@page contentType="text/html" pageEncoding="ISO-8859-1"%>
<%@ taglib prefix="c" 
           uri="http://java.sun.com/jsp/jstl/core" %>
<!DOCTYPE html>
<html>
    <head>
        <meta http-equiv="Content-Type" content="text/html; charset=windows-1252">
        <title>JBoss EAP app on OCP secured by RH-SSO/Keycloak - Example App - Admin page</title>

        <link rel="stylesheet" type="text/css" href="styles.css"/>
    </head>
    <body style="display: block">
        <div class="wrapper">
            <div class="content">
                <div class="message" id="message">This is a protected page: if you see it, it means you are logged in at least with role "admin".</div>
                <a href="index.jsp">Go back to main page</a>
            </div>
        </div>
    </body>
</html>
