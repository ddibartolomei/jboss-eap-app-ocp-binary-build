package com.redhat.ocp.eap;

import javax.enterprise.context.ApplicationScoped;
import javax.inject.Inject;
import javax.persistence.EntityManager;

@ApplicationScoped
public class PersonRepository {

    @Inject
    private EntityManager em;

    public Person findByName(String name) {
        return em.find(Person.class, name);
    }
}