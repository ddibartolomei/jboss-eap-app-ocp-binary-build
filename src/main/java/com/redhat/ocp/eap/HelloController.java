package com.redhat.ocp.eap;

import javax.inject.Inject;
import javax.ws.rs.GET;
import javax.ws.rs.Path;
import javax.ws.rs.PathParam;
import javax.ws.rs.Produces;

@Path("/")
public class HelloController {
    @Inject
    HelloService helloService;

    @GET
    @Path("/person/{name}")
    @Produces({ "application/json" })
    public String getHelloJSON(@PathParam("name") String name) {
        return "{\"result\":\"" + helloService.createHelloMessage(name) + "\"}";
    }

}
