import React, { useState, useEffect } from "react";
import { Link } from "react-router-dom";

export const DropdownMenu: React.FC<{
  items: { name: string; url: string }[];
  label: string;
}> = ({ label, items }) => {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const close = () => setOpen(false);
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  });

  return (
    <div className="dropdown" onClick={() => setOpen(true)}>
      {label}
      <ul className={open ? "dropdown-content show" : "dropdown"} onMouseDown={e => e.stopPropagation()}>
        {items.map((item) => (
          <li className="menu-item" key={item.name}>
            <Link className="black" to={`docs/${item.url}`}>
              {item.name}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
};