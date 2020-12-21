<%@page contentType="text/html" pageEncoding="ISO-8859-1"%>
<%@ taglib prefix="c" 
           uri="http://java.sun.com/jsp/jstl/core" %>
<!DOCTYPE html>
<html>
    <head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <title>JBoss EAP app on OCP secured by RH-SSO/Keycloak - Example App - Main page</title>

        <link rel="stylesheet" type="text/css" href="styles.css"/>
    </head>
    <body style="display: block">
        <jsp:useBean id="controller" class="com.redhat.ocp.eap.Controller" scope="request"/>
        <% controller.handleLogout(request); %>
        
        <c:set var="isLoggedIn" value="<%=controller.isLoggedIn(request)%>"/>
        
        <c:if test="${isLoggedIn}">
            <c:set var="accountUri" value="<%=controller.getAccountUri(request)%>"/>
        </c:if>
        
        <div class="wrapper">
            <c:if test="${!isLoggedIn}">
                <div id="not-authenticated" style="display: block" class="menu">
                    <button name="loginBtn" onclick="location.href = 'protected.jsp'" type="button">Login</button>
                </div>
            </c:if>

            <c:if test="${isLoggedIn}">
                <div id="authenticated" style="display: block" class="menu">
                    <button name="logoutBtn" onclick="location.href = 'index.jsp?action=logout'">Logout</button>
                    <button name="accountBtn" onclick="location.href = '${accountUri}'" type="button">Account</button>
                </div>
            </c:if>

            <div class="content">
                <button name="securedBtn" onclick="location.href = 'protected_user.jsp'">User page</button>
                <button name="adminBtn" onclick="location.href = 'protected_admin.jsp'">Admin page</button>
                <div class="message" id="message"><% out.print(controller.getMessage(request)); %></div>
                <ul>
                    <li><a href="rest/person/john">Test rest and database (call rest/person/john)</a></li>
                    <li><a href="rest/person/bill">Test rest and database (call rest/person/bill)</a></li>
                </ul>
            </div>
        </div>
    </body>
</html>